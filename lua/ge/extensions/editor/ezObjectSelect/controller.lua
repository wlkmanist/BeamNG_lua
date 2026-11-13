-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {
  id = "ezObjectSelect",
  label = "Easy Select"
}

local ffi = require("ffi")
local im = ui_imgui
local cameraBookmarks = require("editor/ezObjectSelect/cameraBookmarks")
local fence = require("editor/ezObjectSelect/subtools/fence/controller")
local transformOperator = require("editor/ezObjectSelect/transformOperator")
local nativeGizmo = require("editor/ezObjectSelect/nativeGizmo")
local objectBoxAnchors = require("editor/ezObjectSelect/objectBoxAnchors")
local objectHistoryActions = require("editor/api/objectHistoryActions")()
local rotateOperator = require("editor/ezObjectSelect/rotateOperator")
local scaleOperator = require("editor/ezObjectSelect/scaleOperator")
local selectionDebug = require("editor/ezObjectSelect/selectionDebug")
local selectionGeometry = require("editor/ezObjectSelect/selectionGeometry")
local selectionModel = require("editor/ezObjectSelect/selectionModel")
local selectionQuery = require("editor/ezObjectSelect/selectionQuery")
local selectabilityPresets = require("editor/api/selectabilityPresets")
local stats = require("editor/ezObjectSelect/stats")
local transformSession = require("editor/ezObjectSelect/transformSession")
local viewportOrientationGizmo = require("editor/ezObjectSelect/viewportOrientationGizmo")

local cfg = {
  discoveryRadius = im.IntPtr(100),
  maxDiscoveryOutlines = im.IntPtr(5),
  maxStackOutlines = im.IntPtr(5),
  maxPickDistance = im.FloatPtr(150),
  maxStackDistance = im.FloatPtr(200),
  maxPickVolume = im.FloatPtr(500000),
  showVolumeFilteredObjects = im.BoolPtr(false),
  showDistanceRing = im.BoolPtr(true),
  showHoverRing = im.BoolPtr(true),
  selectedTintEnabled = im.BoolPtr(false),
  outlineMode = im.IntPtr(0),
  labelPlacementMode = im.IntPtr(1),
  boundsDepthTest = im.BoolPtr(true),
  selectedBoundsDepthTest = im.BoolPtr(true),
  dragBoundsDepthTest = im.BoolPtr(true),
  showOrientationGizmo = im.BoolPtr(true),
  orientationGizmoTopOffset = im.IntPtr(140),
  orientationGizmoRightOffset = im.IntPtr(75),
  showMoveConstraintPlane = im.BoolPtr(true),
  clipMoveConstraintPlane = im.BoolPtr(true),
  suppressCameraForGrs = im.BoolPtr(false),
  numpadMode = im.IntPtr(0),
  defaultCoordinateMode = im.IntPtr(0),
  selectionGizmoLengthScale = im.FloatPtr(2),
  selectionGizmoLineWidth = im.FloatPtr(4),
  debugEnabled = im.BoolPtr(false),
  patternFilter = im.ArrayChar(256, ""),
  ignorePatternFilter = im.ArrayChar(256, ""),
  patternMru = {},
  ignorePatternMru = {},
  maxPatternMru = 10,
  dragProjectionMode = im.IntPtr(0),
  terrainSnapEnabled = im.BoolPtr(true),
  placementMode = im.IntPtr(0),
  raycastVerticalOffset = im.FloatPtr(2),
  treatObjectsIndividually = im.BoolPtr(true),
  gridSnap = im.BoolPtr(false),
  gridSnapMode = im.IntPtr(0),
  gridSize = im.FloatPtr(1),
  gridPresetIndex = im.IntPtr(4),
  gridPresetValues = {"0.1", "0.2", "0.25", "0.5", "1", "1.5", "2", "2.5", "3", "4", "5", "10", "15", "20"},
  rotateSnapEnabled = im.BoolPtr(false),
  rotateSnapMode = im.IntPtr(0),
  rotateSnapSize = im.FloatPtr(15),
  rotatePresetIndex = im.IntPtr(1),
  rotatePresetValues = {"5", "15", "22.5", "45"},
  followRotation = im.BoolPtr(true),
  surfacePlacementMode = im.IntPtr(3),
  surfacePlacementItems = im.ArrayCharPtrByTbl({
    "Origin",
    "Center",
    "Bounding box bottom",
    "Keep height",
    "Long-edge",
    "Short-edge",
    "Short-edge at origin Z"
  }),
  showSurfaceFitPoints = im.BoolPtr(true)
}
cfg.gridPresetItems = im.ArrayCharPtrByTbl(cfg.gridPresetValues)
cfg.rotatePresetItems = im.ArrayCharPtrByTbl(cfg.rotatePresetValues)

local st = {
  active = false,
  latestSelectionSnapshot = nil,
  performanceFrameId = 0,
  selectedTintNeedsRefresh = false,
  wheelZoomBlocked = nil,
  modalInputBlocked = nil,
  cameraMovementBlocked = nil,
  numpadActionsBlocked = nil,
  blenderActionMapPushed = false,
  numpadActionMapPushed = false,
  numpadPresetRequested = nil,
  orthoActive = false,
  transformShortcutRequested = false,
  rotateShortcutRequested = false,
  scaleShortcutRequested = false,
  nativeGizmoVisible = false,
  nativeGizmoMode = nil,
  dragPlaneZ = nil,
  dragBoxCenterOffset = nil,
  dragBoxBottomCenterOffset = nil,
  dragSurfaceFitData = nil,
  dragIndividualData = {},
  dragMouseStart = nil,
  dragScreenGroundStartPosition = nil,
  dragGroundRight = nil,
  dragGroundForward = nil,
  dragWorldPerPixel = nil,
  dragSurfaceFitSamples = {},
  wheelRotateActive = false,
  wheelRotateAngle = 0,
  wheelRotateAxis = nil,
  wheelRotatePivot = nil
}

local keys = {
  escape = im.GetKeyIndex(im.Key_Escape)
}

local uiTheme = {
  surfaceFitSampleColor = ColorF(1, 0, 0, 0.4),
  surfaceFitSampleColor2 = ColorF(1, 0, 0, 1.0),
  hintBindingColor = im.ImVec4(0.1, 0.85, 1, 1),
  wheelFilterGroup = "ezObjectSelectWheel",
  modalFilterGroup = "ezObjectSelectModal",
  cameraMovementFilterGroup = "ezObjectSelectCameraMovement",
  numpadFilterGroup = "ezObjectSelectNumpad",
  blenderActionMap = "EZObjectSelectBlender",
  numpadActionMap = "EZObjectSelectNumpad",
  pickQuerySafetyPixels = 8,
  selectabilityScopeOwner = {}
}

local modalOperators = {
  {id = "transform", label = "G TRANSFORM", operator = transformOperator},
  {id = "rotate", label = "R ROTATE", operator = rotateOperator},
  {id = "scale", label = "S SCALE", operator = scaleOperator}
}

local prefUi = {}

local function activeModalOperator()
  for _, entry in ipairs(modalOperators) do
    if entry.operator.isActive() then return entry end
  end
end

local function cancelModalOperators()
  for _, entry in ipairs(modalOperators) do entry.operator.cancel() end
end

local function setPatternBuffer(buffer, value)
  value = value or ""
  ffi.fill(buffer, 256, 0)
  ffi.copy(buffer, value, math.min(#value, 255))
end

local function rememberPattern(mru, value)
  if not value or value == "" then return end
  for index = #mru, 1, -1 do
    if mru[index] == value then table.remove(mru, index) end
  end
  table.insert(mru, 1, value)
  while #mru > cfg.maxPatternMru do table.remove(mru) end
end

local patternTooltip = table.concat({
  "Case-sensitive Lua pattern\n",
  "Each pattern is matched independently against the object name, internal name, shape path, and model file.",
  "Pattern includes matching objects. Ignore Pattern excludes matching objects and wins when both match.",
  "An empty Pattern accepts all objects; an empty Ignore Pattern excludes nothing.",
  "Separate alternatives with commas for OR matching. Surrounding whitespace and empty entries are ignored.",
  "Commas are delimiters and cannot be part of a pattern.",
  "Plain text matches a substring. Lua syntax includes ^ start, $ end, . any character, %d digits, %a letters,",
  "[abc] sets, * zero or more, + one or more, - shortest repetition, and ? optional.",
  "Prefix Lua magic characters with % to match them literally; for example, %. matches a period.",
  "Invalid patterns disable selection until fixed.",
  "Examples:\n",
  "  tree           contains 'tree'",
  "  tree, rock     matches text containing 'tree' or 'rock'",
  "  ^prop_         starts with 'prop_'",
  "  vehicle$       ends with 'vehicle'",
  "  ^r%d+$         'r' followed only by digits",
  "  %.dae$         ends with '.dae'"
}, "\n")

local function drawPatternInput(label, id, buffer, mru)
  im.TextUnformatted(label)
  im.SetNextItemWidth(180 * im.uiscale[0])
  local submitted = im.InputText(
    "##" .. id,
    buffer,
    256,
    im.InputTextFlags_EnterReturnsTrue)
  local committed = submitted or im.IsItemDeactivatedAfterEdit()
  im.tooltip(patternTooltip)
  if committed then rememberPattern(mru, ffi.string(buffer)) end

  im.SameLine()
  if im.Button("Clear##" .. id) then setPatternBuffer(buffer, "") end
  im.SameLine()
  im.SetNextItemWidth(100 * im.uiscale[0])
  if #mru == 0 then im.BeginDisabled() end
  local selectedMru = nil
  if im.BeginCombo("##" .. id .. "Mru", string.format("Recent (%d)", #mru)) then
    for _, value in ipairs(mru) do
      if im.Selectable1(value, false) then selectedMru = value end
    end
    im.EndCombo()
  end
  if #mru == 0 then im.EndDisabled() end
  if selectedMru then
    setPatternBuffer(buffer, selectedMru)
    rememberPattern(mru, selectedMru)
  end

  local pattern = ffi.string(buffer)
  if pattern ~= "" then
    local valid, patternError = selectionQuery.validatePatternList(pattern)
    if not valid then
      im.TextColored(im.ImVec4(1, 0.25, 0.2, 1), "Invalid pattern: " .. tostring(patternError))
    end
  end
end

local function setWheelZoomBlocked(blocked)
  local actionFilter = extensions.core_input_actionFilter or core_input_actionFilter
  if not actionFilter then return end
  actionFilter.setGroup(uiTheme.wheelFilterGroup, {"editorCameraZoom", "changeCameraSpeed"})
  if st.wheelZoomBlocked == blocked then return end
  actionFilter.addAction(0, uiTheme.wheelFilterGroup, blocked)
  st.wheelZoomBlocked = blocked
end

local function setCameraMovementBlocked(blocked)
  local actionFilter = extensions.core_input_actionFilter or core_input_actionFilter
  if not actionFilter then return end
  actionFilter.setGroup(
    uiTheme.cameraMovementFilterGroup,
    {"moveleft", "moveright", "moveforward", "movebackward"})
  if st.cameraMovementBlocked == blocked then return end
  actionFilter.addAction(0, uiTheme.cameraMovementFilterGroup, blocked)
  st.cameraMovementBlocked = blocked
  if blocked then
    core_camera.clearInputs()
    MoveManager.left = 0
    MoveManager.right = 0
    MoveManager.forward = 0
    MoveManager.backward = 0
  end
end

local function setBlenderBindingsEnabled(enabled)
  if enabled and not st.blenderActionMapPushed then
    pushActionMapHighestPriority(uiTheme.blenderActionMap)
    st.blenderActionMapPushed = true
  elseif not enabled and st.blenderActionMapPushed then
    popActionMap(uiTheme.blenderActionMap)
    st.blenderActionMapPushed = false
  end
  if not enabled then
    st.transformShortcutRequested = false
    st.rotateShortcutRequested = false
    st.scaleShortcutRequested = false
  end
end

local function clearNumpadCameraInputs()
  if core_camera then
    if core_camera.clearInputs then core_camera.clearInputs() end
    if core_camera.setLookBack then pcall(core_camera.setLookBack, 0, false) end
  end
  MoveManager.up = 0
  MoveManager.down = 0
  MoveManager.absZAxis = 0
end

local function setNumpadActionsBlocked(blocked)
  local actionFilter = extensions.core_input_actionFilter or core_input_actionFilter
  if actionFilter then
    actionFilter.setGroup(uiTheme.numpadFilterGroup, {
      "rotate_camera_left",
      "rotate_camera_right",
      "rotate_camera_up",
      "rotate_camera_down",
      "rotate_camera_horizontal",
      "rotate_camera_vertical",
      "look_back",
      "center_camera",
      "decrease_zoom_or_freecam_down",
      "increase_zoom_or_freecam_up"
    })
    if st.numpadActionsBlocked ~= blocked then
      clearNumpadCameraInputs()
      actionFilter.addAction(0, uiTheme.numpadFilterGroup, blocked)
      st.numpadActionsBlocked = blocked
    end
  end
  if blocked and not st.numpadActionMapPushed then
    pushActionMapHighestPriority(uiTheme.numpadActionMap)
    st.numpadActionMapPushed = true
  elseif not blocked and st.numpadActionMapPushed then
    popActionMap(uiTheme.numpadActionMap)
    st.numpadActionMapPushed = false
  end
end

local function setOrthoEnabled(enabled, size)
  local orthoModule = extensions.core_orthoCamera
  if not orthoModule then
    extensions.load("core_orthoCamera")
    orthoModule = extensions.core_orthoCamera
  end
  if not orthoModule then return end
  if enabled then
    st.orthoActive = true
    orthoModule.enable(true, {
      size = size or 25,
      nearClip = 0.1,
      farClip = 50000,
      useWindowAspectRatio = true
    })
  else
    st.orthoActive = false
    orthoModule.enable(false)
  end
end

local function setModalInputBlocked(blocked)
  local actionFilter = extensions.core_input_actionFilter or core_input_actionFilter
  if not actionFilter then return end
  actionFilter.setGroup(uiTheme.modalFilterGroup, {
    "moveleft",
    "moveright",
    "moveforward",
    "movebackward",
    "moveup",
    "movedown",
    "moveforwardbackward",
    "moveleftright",
    "xAxisAbs",
    "yAxisAbs",
    "zAxisAbs",
    "pitchAbs",
    "rollAbs",
    "yawAbs",
    "rotate_camera_left",
    "rotate_camera_right",
    "rotate_camera_up",
    "rotate_camera_down",
    "rotate_camera_horizontal",
    "rotate_camera_vertical",
    "editorCameraZoom",
    "increase_zoom",
    "decrease_zoom",
    "changeCameraSpeed",
    "editorGameCamera",
    "editorFreeCamera",
    "editorToggleFreeCamera",
    "editorFitViewToSelection",
    "editorPlaceCameraAtSelection",
    "camera_1",
    "camera_2",
    "camera_3",
    "camera_4",
    "camera_5",
    "camera_6",
    "camera_7",
    "camera_8",
    "camera_9",
    "editorDeselect",
    "editorDeleteSelection",
    "editorCut",
    "editorCopy",
    "editorPaste",
    "editorDuplicate",
    "editorDuplicateAtCamera",
    "editorSelectAll",
    "editorUndo",
    "editorRedo",
    "editorLockSelection",
    "editorUnlockSelection",
    "editorHideSelection",
    "editorShowSelection",
    "editorResetTransforms",
    "editorResetRotations",
    "editorMoveSelectionAtCamera",
    "editorSetSelectionTransformFromCamera",
    "ezSelectFocus",
    "editorSetTranslateMode",
    "editorSetRotateMode",
    "editorSetScaleMode"
  })
  if st.modalInputBlocked == blocked then return end
  actionFilter.addAction(0, uiTheme.modalFilterGroup, blocked)
  st.modalInputBlocked = blocked
end

function M.resetInputFilters()
  st.wheelZoomBlocked = nil
  st.cameraMovementBlocked = nil
  st.modalInputBlocked = nil
  st.numpadActionsBlocked = nil
  setWheelZoomBlocked(false)
  setCameraMovementBlocked(false)
  setModalInputBlocked(false)
  setNumpadActionsBlocked(false)
  popActionMap(uiTheme.blenderActionMap)
  popActionMap(uiTheme.numpadActionMap)
  st.blenderActionMapPushed = false
  st.numpadActionMapPushed = false
  st.transformShortcutRequested = false
  st.rotateShortcutRequested = false
  st.scaleShortcutRequested = false
  clearNumpadCameraInputs()
end

local function clearDragState()
  st.dragPlaneZ = nil
  st.dragBoxCenterOffset = nil
  st.dragBoxBottomCenterOffset = nil
  st.dragSurfaceFitData = nil
  st.dragMouseStart = nil
  st.dragScreenGroundStartPosition = nil
  st.dragGroundRight = nil
  st.dragGroundForward = nil
  st.dragWorldPerPixel = nil
  table.clear(st.dragIndividualData)
  table.clear(st.dragSurfaceFitSamples)
end

local function endDirectTransform(commit, reason)
  if commit then
    local _, completion = transformSession.finish()
    if completion then
      stats.recordOperation("transform", "direct", completion.anchorDistance)
    end
  else
    transformSession.cancel()
  end
  selectionModel.invalidateCache(reason)
  selectionModel.releasePick()
  clearDragState()
  setWheelZoomBlocked(false)
  setModalInputBlocked(false)
end

local function clearWheelRotation(commit)
  if st.wheelRotateActive then
    if commit then
      local _, completion = transformSession.finish()
      if completion then stats.recordOperation("rotate", "wheel") end
    else
      transformSession.cancel()
    end
  end
  st.wheelRotateActive = false
  st.wheelRotateAngle = 0
  st.wheelRotateAxis = nil
  st.wheelRotatePivot = nil
  setWheelZoomBlocked(false)
  setModalInputBlocked(false)
end

local function resetAllSelectionState()
  cancelModalOperators()
  clearWheelRotation(false)
  selectionModel.activate()
  selectionDebug.reset()
  st.latestSelectionSnapshot = nil
  st.transformShortcutRequested = false
  st.rotateShortcutRequested = false
  st.scaleShortcutRequested = false
  setWheelZoomBlocked(false)
  setModalInputBlocked(false)
  worldEditorCppApi.setHoveredObjectId(0)
end

local validBox = selectionGeometry.validBox
local getCameraContext = selectionGeometry.createCameraContext

local function inputAvailable()
  return editor.isViewportHovered()
    and not im.GetIO().WantCaptureMouse
    and not im.IsAnyItemActive()
    and not editor.isWindowVisible("fileDialog")
end

local function drawSurfaceFitSamples()
  if not cfg.showSurfaceFitPoints[0] then return end
  for _, sample in ipairs(st.dragSurfaceFitSamples) do
    debugDrawer:drawSphere(sample, 0.01, uiTheme.surfaceFitSampleColor2, false)
    debugDrawer:drawSphere(sample, 0.10, uiTheme.surfaceFitSampleColor, false)
  end
end

function M.drawScreenDebug()
  if not st.active then return end
  if fence.isModeActive() then return end
  local modal = activeModalOperator()
  local draggingLabel = modal and modal.label
    or (cfg.dragProjectionMode[0] == 0
      and "DRAGGING / RAYCAST"
      or "DRAGGING / SCREEN")
  local snapshot = st.latestSelectionSnapshot
  if not snapshot and (cfg.debugEnabled[0] or cfg.showHoverRing[0]) then
    local camera = getCameraContext()
    if camera then
      local screenMouse = im.GetMousePos()
      local clientMouse = editor.screenToClient(Point2I(screenMouse.x, screenMouse.y))
      snapshot = {
        camera = camera,
        mouse = {x = clientMouse.x, y = clientMouse.y},
        queryRadius = cfg.discoveryRadius[0] * im.uiscale[0] + uiTheme.pickQuerySafetyPixels,
        discoveryRadius = cfg.discoveryRadius[0] * im.uiscale[0],
        candidates = {},
        discovery = {},
        queryStats = {screen = 0, nearCamera = 0, nearOnly = 0, total = 0},
        rejected = {},
        sourceCount = 0,
        stackCount = 0,
        activeIndex = 0,
        pick = nil,
        cycleActive = false
      }
    end
  end
  selectionDebug.drawScreen(snapshot, {
    debugSelectionText = cfg.debugEnabled[0],
    debugEnabled = cfg.debugEnabled[0],
    discoveryPixels = cfg.discoveryRadius[0] * im.uiscale[0],
    maxDiscoveryOutlines = cfg.maxDiscoveryOutlines[0],
    maxStackOutlines = cfg.maxStackOutlines[0],
    draggingIds = transformSession.getObjectIds(),
    draggingLabel = draggingLabel,
    labelPlacementMode = cfg.labelPlacementMode[0],
    outlineMode = cfg.outlineMode[0],
    showSelectedTint = cfg.selectedTintEnabled[0],
    showHoverRing = cfg.showHoverRing[0],
    hideHoverRing = modal ~= nil,
    selectedIds = editor.selection.object
  })
  if cfg.showOrientationGizmo[0] then
    local selectedIds = editor.selection.object or {}
    local localObjectId = cfg.defaultCoordinateMode[0] == 1 and selectedIds[#selectedIds] or nil
    viewportOrientationGizmo.draw(
      cfg.orientationGizmoRightOffset[0],
      cfg.orientationGizmoTopOffset[0],
      localObjectId)
  end
  if modal then
    modal.operator.drawScreen({
      gridSize = cfg.gridSnap[0] and cfg.gridSize[0] or nil,
      gridRelative = cfg.gridSnapMode[0] == 1
    })
  end
end

local function selectionMode()
  if editor.keyModifiers.ctrl then return editor.SelectMode_Toggle end
  if editor.keyModifiers.alt then return editor.SelectMode_Remove end
  if editor.keyModifiers.shift then return editor.SelectMode_Add end
  return editor.SelectMode_New
end

local function selectCandidate(candidate)
  local oldSelection = deepcopy(editor.selection.object)
  local mode = selectionMode()
  local targetId = candidate and candidate.target:getID() or nil
  local wasSelected = targetId and editor.isObjectSelected(targetId) or false
  if candidate then
    editor.selectObjectById(targetId, mode)
  elseif mode == editor.SelectMode_New then
    editor.clearObjectSelection()
  end
  objectHistoryActions.selectObjectsWithUndo(editor.selection.object, oldSelection)
  if targetId and not wasSelected and editor.isObjectSelected(targetId) then
    stats.recordSelection()
  end
end

local function belongsToSelection(obj)
  if not obj then return false end
  if editor.isObjectSelected(obj:getID()) then return true end
  local prefab = getOwningPrefab(obj) or getOwningPrefabInstance(obj)
  return prefab and editor.isObjectSelected(prefab:getID()) or false
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

local function verticalRaycastAt(point)
  local origin = vec3(point.x, point.y, point.z + cfg.raycastVerticalOffset[0])
  local target = vec3(point.x, point.y, point.z - 5000)
  local suppressedObjects = {}
  local suppressedIds = {}
  local function suppressCollision(obj)
    if not obj or not obj.disableCollision then return false end
    local id = obj:getID()
    if suppressedIds[id] then return false end
    suppressedIds[id] = true
    local wasEnabled = collisionEnabledState(obj)
    if wasEnabled ~= true then return wasEnabled == false end
    obj:disableCollision()
    suppressedObjects[#suppressedObjects + 1] = {id = id, wasEnabled = wasEnabled}
    return true
  end

  local ok, result = xpcall(function()
    for _, id in ipairs(editor.selection.object or {}) do
      suppressCollision(scenetree.findObjectById(id))
    end

    for _ = 1, 16 do
      local hit = Engine.castRay(origin, target, true, true)
      if not hit then break end

      local hitObject = hit.obj
      if hitObject and belongsToSelection(hitObject) then
        if not suppressCollision(hitObject) then break end
      else
        return {pos = vec3(hit.pt), normal = vec3(hit.norm)}
      end
    end
    return nil
  end, debug.traceback)

  for _, entry in ipairs(suppressedObjects) do
    local obj = scenetree.findObjectById(entry.id)
    if obj then
      pcall(function()
        if entry.wasEnabled == false then
          if obj.disableCollision then obj:disableCollision() end
        elseif obj.enableCollision then
          obj:enableCollision()
        end
      end)
    end
  end
  if not ok then
    log("E", "ezObjectSelect", "Selected-object raycast failed: " .. tostring(result))
    return nil
  end
  return result
end

local function snapPointToSurface(point)
  if cfg.placementMode[0] == 0 then
    local sample = vec3(point)
    local height = core_terrain.getTerrainHeight(sample)
    if not height then return nil end
    sample.z = height
    return {
      pos = sample,
      normal = core_terrain.getTerrainSmoothNormal(sample) or vec3(0, 0, 1)
    }
  end
  return verticalRaycastAt(point)
end

local function screenGroundPlacementPoint()
  if not st.dragMouseStart or not st.dragScreenGroundStartPosition
    or not st.dragGroundRight or not st.dragGroundForward or not st.dragWorldPerPixel then
    return nil
  end

  local mouse = im.GetMousePos()
  local deltaX = (mouse.x - st.dragMouseStart.x) * st.dragWorldPerPixel
  local deltaY = (mouse.y - st.dragMouseStart.y) * st.dragWorldPerPixel
  local point = st.dragScreenGroundStartPosition
    + st.dragGroundRight * deltaX
    - st.dragGroundForward * deltaY
  return cfg.terrainSnapEnabled[0] and snapPointToSurface(point)
    or {pos = point, normal = vec3(0, 0, 1)}
end

local function placementPoint()
  local ray = getCameraMouseRay()
  if not ray then return nil end
  local origin = vec3(ray.pos)
  local direction = vec3(ray.dir)
  local directionLength = direction:length()
  if directionLength <= 0.0001 then return nil end
  direction = direction / directionLength

  if cfg.dragProjectionMode[0] == 1 then return screenGroundPlacementPoint() end

  if not cfg.terrainSnapEnabled[0] then
    if not st.dragPlaneZ or math.abs(direction.z) <= 0.0001 then return nil end
    local distance = (st.dragPlaneZ - origin.z) / direction.z
    if distance < 0 then return nil end
    return {pos = origin + direction * distance, normal = vec3(0, 0, 1)}
  end

  if cfg.placementMode[0] == 0 then
    local hit = cameraMouseRayCast(false, SOTTerrain)
    if not hit then return nil end
    return {
      pos = hit.pos and vec3(hit.pos) or vec3(hit.pt),
      normal = hit.normal and vec3(hit.normal) or (hit.norm and vec3(hit.norm) or vec3(0, 0, 1))
    }
  end

  if not st.dragPlaneZ or math.abs(direction.z) <= 0.0001 then return nil end
  local distance = (st.dragPlaneZ - origin.z) / direction.z
  if distance < 0 then return nil end
  local projectedPoint = origin + direction * distance

  return verticalRaycastAt(projectedPoint)
end

local function sampleSurfaceAt(point)
  if not cfg.terrainSnapEnabled[0] then return nil end
  return snapPointToSurface(point)
end

local function setSurfaceFitSamples(samples)
  table.clear(st.dragSurfaceFitSamples)
  for _, sample in ipairs(samples or {}) do
    local position = type(sample) == "table" and sample.pos or sample
    if position then st.dragSurfaceFitSamples[#st.dragSurfaceFitSamples + 1] = vec3(position) end
  end
end

local function surfaceFitDataForObject(obj)
  return objectBoxAnchors.describeObject(obj)
end

local function isMultiPointSurfaceMode(mode)
  return mode >= 4
end

local function isBottomSurfaceMode(mode)
  return mode == 2 or mode == 4 or mode == 5
end

local function fitPatternForMode(fitData, mode)
  if mode == 4 then return fitData.longEdge end
  if mode == 5 then return fitData.shortEdge end
  if mode == 6 then return fitData.shortEdgeOrigin end
end

local function edgeMidpointFit(originPosition, fitData, surfaceZ, mode)
  local pattern = fitPatternForMode(fitData, mode)
  if not pattern then return nil end
  local firstPoint = vec3(originPosition) + pattern.firstOffset
  local secondPoint = vec3(originPosition) + pattern.secondOffset
  firstPoint.z = surfaceZ
  secondPoint.z = surfaceZ
  local firstSample = sampleSurfaceAt(firstPoint)
  local secondSample = sampleSurfaceAt(secondPoint)
  if not firstSample or not secondSample then return nil end

  local tangent = secondSample.pos - firstSample.pos
  local axis = secondPoint - firstPoint
  axis.z = 0
  if axis:length() <= 0.0001 then return nil end
  axis:normalize()
  local lateral = vec3(-axis.y, axis.x, 0)
  local normal = tangent:cross(lateral)
  if normal.z < 0 then normal:setScaled(-1) end
  local normalLength = normal:length()
  if normalLength <= 0.0001 then return nil end
  return {
    height = (firstSample.pos.z + secondSample.pos.z) * 0.5,
    normal = normal / normalLength,
    samples = {firstSample, secondSample}
  }
end

local function fittedSurface(surfacePosition, options, anchorOverride, fitData)
  fitData = fitData or st.dragSurfaceFitData
  local mode = cfg.surfacePlacementMode[0]
  if not fitData or not isMultiPointSurfaceMode(mode) then return nil end
  local anchorPosition = anchorOverride or transformSession.getDesiredAnchorPosition(surfacePosition, options)
  if not anchorPosition then return nil end
  local fit = edgeMidpointFit(
    anchorPosition,
    fitData,
    surfacePosition.z,
    mode)
  if not fit then return nil end
  setSurfaceFitSamples(fit.samples)
  local fittedPosition = vec3(surfacePosition)
  fittedPosition.z = fit.height
  return {pos = fittedPosition, normal = fit.normal}
end

local function fittedSingleReference(surface, desiredOrigin, mode)
  local offset = mode == 1 and st.dragBoxCenterOffset
    or (mode == 2 and st.dragBoxBottomCenterOffset or nil)
  if not surface or not desiredOrigin or not offset then return nil end
  local sample = sampleSurfaceAt(vec3(desiredOrigin) + offset)
  if not sample then return nil end
  setSurfaceFitSamples({sample})
  local position = vec3(surface.pos)
  position.z = sample.pos.z
  return {pos = position, normal = sample.normal}
end

local function syncCoordinateMode()
  cfg.defaultCoordinateMode[0] = editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local and 1 or 0
  stats.setCoordinateMode(cfg.defaultCoordinateMode[0] == 1)
end

local function buildIndividualSnapData()
  table.clear(st.dragIndividualData)
  table.clear(st.dragSurfaceFitSamples)
  for _, id in ipairs(editor.selection.object or {}) do
    local obj = scenetree.findObjectById(id)
    if obj and obj.getWorldBox and obj.getPosition then
      local position = vec3(obj:getPosition())
      local box = obj:getWorldBox()
      local fitData = surfaceFitDataForObject(obj)
      local sample = validBox(box)
        and (not isMultiPointSurfaceMode(cfg.surfacePlacementMode[0]) or fitData)
        and sampleSurfaceAt(position)
        or nil
      if sample then
        st.dragSurfaceFitSamples[#st.dragSurfaceFitSamples + 1] = vec3(sample.pos)
        local centerOffset = box:getCenter() - position
        st.dragIndividualData[id] = {
          centerOffset = centerOffset,
          bottomCenterOffset = vec3(centerOffset.x, centerOffset.y, box.minExtents.z - position.z),
          fitData = fitData,
          bottomOffset = box.minExtents.z - position.z,
          heightOffset = sample.pos.z - position.z
        }
      end
    end
  end
end

local function individualSurfaceProvider(entry, desiredPosition)
  local data = st.dragIndividualData[entry.id]
  if not data then return nil end
  local mode = cfg.surfacePlacementMode[0]
  local sample
  if isMultiPointSurfaceMode(mode) then
    local fit = edgeMidpointFit(
      vec3(desiredPosition),
      data.fitData,
      desiredPosition.z,
      mode)
    if not fit then return nil end
    for _, fitSample in ipairs(fit.samples) do
      st.dragSurfaceFitSamples[#st.dragSurfaceFitSamples + 1] = vec3(fitSample.pos)
    end
    sample = {
      pos = vec3(desiredPosition.x, desiredPosition.y, fit.height),
      normal = fit.normal
    }
  else
    local samplePoint = vec3(desiredPosition)
    if mode == 1 then
      samplePoint:setAdd(data.centerOffset)
    elseif mode == 2 then
      samplePoint:setAdd(data.bottomCenterOffset)
    end
    sample = sampleSurfaceAt(samplePoint)
    if not sample then return nil end
    st.dragSurfaceFitSamples[#st.dragSurfaceFitSamples + 1] = vec3(sample.pos)
  end

  local position = vec3(desiredPosition)
  if mode == 0 or mode == 6 then
    position.z = sample.pos.z
  elseif mode == 1 then
    position.z = sample.pos.z - data.centerOffset.z
  elseif isBottomSurfaceMode(mode) then
    position.z = sample.pos.z - data.bottomOffset
  else
    position.z = sample.pos.z - data.heightOffset
  end
  return {position = position, normal = sample.normal}
end

local function transformOptions()
  return {
    gridSize = cfg.gridSnap[0] and cfg.gridSize[0] or nil,
    gridRelative = cfg.gridSnapMode[0] == 1,
    snapZ = not cfg.terrainSnapEnabled[0],
    followRotation = cfg.terrainSnapEnabled[0]
      and (cfg.followRotation[0] or isMultiPointSurfaceMode(cfg.surfacePlacementMode[0])),
    rotateSnapSize = cfg.rotateSnapEnabled[0] and cfg.rotateSnapSize[0] or nil,
    rotateRelative = cfg.rotateSnapMode[0] == 1,
    individualProvider = cfg.terrainSnapEnabled[0] and cfg.treatObjectsIndividually[0]
      and individualSurfaceProvider or nil
  }
end

local function transformOperatorOptions()
  return {
    gridSize = cfg.gridSnap[0] and cfg.gridSize[0] or nil,
    gridRelative = cfg.gridSnapMode[0] == 1,
    showPlane = cfg.showMoveConstraintPlane[0],
    clipPlane = cfg.clipMoveConstraintPlane[0]
  }
end

local function modalOperatorOptions(id)
  if id == "transform" then return transformOperatorOptions() end
  if id == "rotate" then
    return {
      rotateSnapEnabled = cfg.rotateSnapEnabled[0],
      rotateSnapSize = cfg.rotateSnapSize[0]
    }
  end
  return {}
end

local function updateTransformSession()
  if not transformSession.isActive() then return false end
  setWheelZoomBlocked(false)
  setModalInputBlocked(true)
  if not transformSession.selectionMatches() then
    endDirectTransform(false, "transformSelectionMismatch")
    return true
  end
  local draggingLabel = cfg.dragProjectionMode[0] == 0
    and "DRAGGING / RAYCAST"
    or "DRAGGING / SCREEN"
  selectionDebug.drawWorld(nil, {
    axisLengthScale = cfg.selectionGizmoLengthScale[0],
    axisLineWidth = cfg.selectionGizmoLineWidth[0],
    axisLocal = cfg.defaultCoordinateMode[0] == 1,
    debugSelectionText = cfg.debugEnabled[0],
    depthTest = cfg.boundsDepthTest[0],
    selectedDepthTest = cfg.selectedBoundsDepthTest[0],
    dragDepthTest = cfg.dragBoundsDepthTest[0],
    outlineMode = cfg.outlineMode[0],
    maxDiscoveryOutlines = cfg.maxDiscoveryOutlines[0],
    maxStackOutlines = cfg.maxStackOutlines[0],
    showSelectionAxes = true,
    selectedIds = editor.selection.object,
    draggingIds = transformSession.getObjectIds(),
    draggingLabel = draggingLabel
  })

  if im.IsKeyPressed(keys.escape) then
    endDirectTransform(false, "transformCancel")
    return true
  end

  if not im.IsMouseDown(0) then
    endDirectTransform(true, "transformFinish")
    return true
  end

  if im.IsMouseDragging(0, 1) then
    table.clear(st.dragSurfaceFitSamples)
    local point = placementPoint()
    if point then
      local options = transformOptions()
      if cfg.terrainSnapEnabled[0]
        and not cfg.treatObjectsIndividually[0]
        and isMultiPointSurfaceMode(cfg.surfacePlacementMode[0]) then
        point = fittedSurface(point.pos, options) or point
      elseif not cfg.treatObjectsIndividually[0] then
        local mode = cfg.surfacePlacementMode[0]
        if cfg.terrainSnapEnabled[0] and (mode == 1 or mode == 2) then
          local desiredOrigin = transformSession.getDesiredAnchorPosition(point.pos, options)
          point = fittedSingleReference(point, desiredOrigin, mode) or point
        else
          setSurfaceFitSamples({point.pos})
        end
      end
      transformSession.update(point.pos, point.normal, options)
    end
  end
  drawSurfaceFitSamples()
  return true
end

function M.activate()
  if st.active then return true end
  resetAllSelectionState()
  if not selectabilityPresets.beginScope(
    uiTheme.selectabilityScopeOwner,
    "staticsAndProps",
    "Easy Select") then
    selectionModel.deactivate()
    return false
  end
  st.active = true
  st.selectedTintNeedsRefresh = false
  worldEditorCppApi.setAxisGizmoHighlightSelectedMeshes(cfg.selectedTintEnabled[0])
  if extensions.editor_cameraV2 and extensions.editor_cameraV2.setTemporaryEnabled then
    extensions.editor_cameraV2.setTemporaryEnabled(true)
  end
  setBlenderBindingsEnabled(cfg.suppressCameraForGrs[0])
  setCameraMovementBlocked(cfg.suppressCameraForGrs[0])
  setNumpadActionsBlocked(cfg.numpadMode[0] == 1)
  st.nativeGizmoVisible = false
  st.nativeGizmoMode = nil
  nativeGizmo.reset()
  syncCoordinateMode()
  stats.activate(cfg.defaultCoordinateMode[0] == 1)
  worldEditorCppApi.setAxisGizmoSelectedElement(-1)
  return true
end

function M.deactivate()
  if not st.active then return end
  fence.cancel()
  cancelModalOperators()
  clearWheelRotation(false)
  transformSession.cancel()
  nativeGizmo.reset()
  st.nativeGizmoVisible = false
  st.nativeGizmoMode = nil
  st.selectedTintNeedsRefresh = false
  worldEditorCppApi.setAxisGizmoHighlightSelectedMeshes(
    editor.getPreference("gizmos.general.highlightSelectedMeshes") ~= false)
  setBlenderBindingsEnabled(false)
  setCameraMovementBlocked(false)
  setNumpadActionsBlocked(false)
  if st.orthoActive then setOrthoEnabled(false) end
  if extensions.editor_cameraV2 and extensions.editor_cameraV2.setTemporaryEnabled then
    extensions.editor_cameraV2.setTemporaryEnabled(false)
  end
  setWheelZoomBlocked(false)
  setModalInputBlocked(false)
  selectionModel.deactivate()
  selectabilityPresets.endScope(uiTheme.selectabilityScopeOwner)
  worldEditorCppApi.setHoveredObjectId(0)
  st.latestSelectionSnapshot = nil
  st.numpadPresetRequested = nil
  clearDragState()
  st.active = false
end

function M.isActive()
  return st.active
end

function M.refreshSelectedTint()
  if st.active then
    st.selectedTintNeedsRefresh = true
    worldEditorCppApi.setAxisGizmoHighlightSelectedMeshes(cfg.selectedTintEnabled[0])
  end
end

function M.onAxisGizmoModeChanged(mode)
  if not st.active then return end
  if nativeGizmo.isInteracting() then
    if st.nativeGizmoMode then worldEditorCppApi.setAxisGizmoMode(st.nativeGizmoMode) end
    return
  end
  if mode == editor.AxisGizmoMode_Translate
    or mode == editor.AxisGizmoMode_Rotate
    or mode == editor.AxisGizmoMode_Scale then
    if st.nativeGizmoVisible and st.nativeGizmoMode == mode then
      st.nativeGizmoVisible = false
      nativeGizmo.reset()
    else
      st.nativeGizmoVisible = true
      st.nativeGizmoMode = mode
      if editor.updateObjectSelectionAxisGizmo then editor.updateObjectSelectionAxisGizmo() end
    end
  else
    st.nativeGizmoVisible = false
    st.nativeGizmoMode = mode
    nativeGizmo.reset()
  end
end

function M.onAxisGizmoAlignmentChanged()
  if not st.active then return end
  syncCoordinateMode()
  for _, entry in ipairs(modalOperators) do
    if entry.operator.isActive() and entry.operator.setLocalSpace then
      entry.operator.setLocalSpace(cfg.defaultCoordinateMode[0] == 1)
    end
  end
  if nativeGizmo.isInteracting() then return end
  if st.nativeGizmoVisible and editor.updateObjectSelectionAxisGizmo then
    editor.updateObjectSelectionAxisGizmo()
  end
end

function M.invalidateSelectionCache(reason)
  selectionModel.invalidateCache(reason)
  stats.invalidateVolume()
  st.latestSelectionSnapshot = nil
end

local function modalShortcutAvailable()
  return st.active
    and inputAvailable()
    and not activeModalOperator()
    and not transformSession.isActive()
    and not nativeGizmo.isInteracting()
    and not fence.isModeActive()
    and editor.selection.object
    and #editor.selection.object > 0
end

local function stopCameraMovement()
  local actionFilter = extensions.core_input_actionFilter or core_input_actionFilter
  if actionFilter and actionFilter.isActionBlocked("moveforward") then
    core_camera.clearInputs()
    MoveManager.forward = 0
    MoveManager.backward = 0
    MoveManager.left = 0
    MoveManager.right = 0
    MoveManager.up = 0
    MoveManager.down = 0
    MoveManager.absXAxis = 0
    MoveManager.absYAxis = 0
    MoveManager.absZAxis = 0
  end
end

function M.requestTransformShortcut()
  if not cfg.suppressCameraForGrs[0] then return end
  if modalShortcutAvailable() then
    st.transformShortcutRequested = true
    setModalInputBlocked(true)
    stopCameraMovement()
  end
end

function M.requestRotateShortcut()
  if not cfg.suppressCameraForGrs[0] then return end
  if modalShortcutAvailable() then
    st.rotateShortcutRequested = true
    setModalInputBlocked(true)
    stopCameraMovement()
  end
end

function M.requestScaleShortcut()
  if not cfg.suppressCameraForGrs[0] then return end
  if modalShortcutAvailable() then
    st.scaleShortcutRequested = true
    setModalInputBlocked(true)
    stopCameraMovement()
  end
end

local function focusCameraJob(job)
  local camera = job.args[1]
  local step = (camera.endPosition - camera.startPosition) / 80
  local stepPosition = 0
  for currentStep = 0, 20 do
    job.sleep(0.05)
    local position = camera.startPosition + step * stepPosition
    local rotation = quatFromDir(camera.center - camera.endPosition)
    core_camera.setPosRot(
      0,
      position.x,
      position.y,
      position.z,
      rotation.x,
      rotation.y,
      rotation.z,
      rotation.w)
    stepPosition = stepPosition + (currentStep < 12 and 6 or 1)
  end
end

local function focusObjectSmooth(obj)
  local box = obj and obj.getWorldBox and obj:getWorldBox() or nil
  if not validBox(box) then return false end
  local center = box:getCenter()
  local radius = clamp((box.maxExtents - box.minExtents):length(), 20, 16000)
  local rotation = core_camera.getQuat()
  core_jobsystem.create(focusCameraJob, 1, {
    startPosition = vec3(core_camera.getPosition()),
    endPosition = center + rotation * vec3(0, -radius, 0),
    center = center
  })
  return true
end

function M.requestFocusShortcut()
  if not st.active
    or activeModalOperator()
    or transformSession.isActive()
    or nativeGizmo.isInteracting()
    or fence.isModeActive() then
    return
  end
  local candidate = st.latestSelectionSnapshot and st.latestSelectionSnapshot.pick or nil
  if candidate and focusObjectSmooth(candidate.target) then return end
  editor.fitViewToSelectionSmooth()
end

local function getCameraTargetPivot()
  if editor.selection and editor.selection.object and #editor.selection.object > 0 then
    if editor.computeSelectionBBox then editor.computeSelectionBBox() end
    local box = editor.objectSelectionBBox
    if box and box.getCenter then
      local center = vec3(box:getCenter())
      if center and (center.x == center.x) then return center end
    end
  end
  local ray = getCameraMouseRay()
  if ray then
    local hit = Engine.castRay(ray.pos, vec3(ray.pos) + vec3(ray.dir) * 10000, true, true)
    if hit and hit.pt then return vec3(hit.pt) end
  end
  local pos = vec3(core_camera.getPosition())
  local fwd = core_camera.getQuat() * vec3(0, 1, 0)
  return pos + fwd * 25
end

local function getCameraViewBasis()
  local worldX, worldY, worldZ = vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1)
  if editor.getAxisGizmoAlignment() ~= editor.AxisGizmoAlignment_Local then
    return worldX, worldY, worldZ
  end
  local selectedIds = editor.selection and editor.selection.object or {}
  for index = #selectedIds, 1, -1 do
    local obj = scenetree.findObjectById(selectedIds[index])
    if obj and obj.getTransform then
      local transform = obj:getTransform()
      local axisX = vec3(transform:getColumn(0))
      local axisY = vec3(transform:getColumn(1))
      local axisZ = vec3(transform:getColumn(2))
      if axisX:length() > 0.0001 and axisY:length() > 0.0001 and axisZ:length() > 0.0001 then
        return axisX:normalized(), axisY:normalized(), axisZ:normalized()
      end
    end
  end
  return worldX, worldY, worldZ
end

local function snapCameraView(target, fwd, up, distance)
  fwd = fwd:normalized()
  if not up or up:length() < 0.0001 then
    up = vec3(0, 0, 1)
  end
  up = up:normalized()
  local rot = quatFromDir(fwd, up)
  local pos = target - fwd * distance
  if core_camera.clearMotion then core_camera.clearMotion(0) end
  core_camera.setPosRot(0, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
end

function M.requestNumpadPreset(preset)
  if st.active and cfg.numpadMode[0] == 1 then
    st.numpadPresetRequested = preset
  end
end

local function updateNumpadPresets()
  local preset = st.numpadPresetRequested
  st.numpadPresetRequested = nil
  if cfg.numpadMode[0] ~= 1 or not preset then return false end
  if not inputAvailable()
    or activeModalOperator()
    or transformSession.isActive()
    or nativeGizmo.isInteracting()
    or fence.isModeActive() then
    return false
  end
  if im.GetIO().WantCaptureKeyboard or im.IsAnyItemActive() then return false end

  local ctrl = editor.keyModifiers and editor.keyModifiers.ctrl
  local axisX, axisY, axisZ = getCameraViewBasis()

  if preset == "front" then
    local target = getCameraTargetPivot()
    local camPos = vec3(core_camera.getPosition())
    local dist = math.max((camPos - target):length(), 5)
    local fwd = ctrl and -axisY or axisY
    local up = axisZ
    snapCameraView(target, fwd, up, dist)
    return true
  elseif preset == "side" then
    local target = getCameraTargetPivot()
    local camPos = vec3(core_camera.getPosition())
    local dist = math.max((camPos - target):length(), 5)
    local fwd = ctrl and axisX or -axisX
    local up = axisZ
    snapCameraView(target, fwd, up, dist)
    return true
  elseif preset == "top" then
    local target = getCameraTargetPivot()
    local camPos = vec3(core_camera.getPosition())
    local dist = math.max((camPos - target):length(), 5)
    local fwd = ctrl and axisZ or -axisZ
    local up = ctrl and -axisY or axisY
    snapCameraView(target, fwd, up, dist)
    return true
  elseif preset == "projection" then
    local target = getCameraTargetPivot()
    local camPos = vec3(core_camera.getPosition())
    local dist = math.max((camPos - target):length(), 5)
    setOrthoEnabled(not st.orthoActive, dist * 0.8)
    return true
  elseif preset == "opposite" then
    local target = getCameraTargetPivot()
    local camPos = vec3(core_camera.getPosition())
    local dist = math.max((camPos - target):length(), 5)
    local curFwd = core_camera.getQuat() * vec3(0, 1, 0)
    local curUp = core_camera.getQuat() * vec3(0, 0, 1)
    snapCameraView(target, -curFwd, curUp, dist)
    return true
  elseif preset == "frame" then
    if editor.fitViewToSelectionSmooth then
      editor.fitViewToSelectionSmooth()
    elseif editor.fitViewToSelection then
      editor.fitViewToSelection()
    end
    return true
  elseif preset == "orbitLeft" then
    local target = getCameraTargetPivot()
    local camPos = vec3(core_camera.getPosition())
    local offset = camPos - target
    local rotZ = quatFromEuler(0, 0, math.rad(15))
    local newOffset = rotZ * offset
    local newCamPos = target + newOffset
    local fwd = (target - newCamPos):normalized()
    local curUp = core_camera.getQuat() * vec3(0, 0, 1)
    snapCameraView(target, fwd, curUp, newOffset:length())
    return true
  elseif preset == "orbitRight" then
    local target = getCameraTargetPivot()
    local camPos = vec3(core_camera.getPosition())
    local offset = camPos - target
    local rotZ = quatFromEuler(0, 0, -math.rad(15))
    local newOffset = rotZ * offset
    local newCamPos = target + newOffset
    local fwd = (target - newCamPos):normalized()
    local curUp = core_camera.getQuat() * vec3(0, 0, 1)
    snapCameraView(target, fwd, curUp, newOffset:length())
    return true
  elseif preset == "orbitUp" then
    local target = getCameraTargetPivot()
    local camPos = vec3(core_camera.getPosition())
    local offset = camPos - target
    local curRight = core_camera.getQuat() * vec3(1, 0, 0)
    curRight.z = 0
    curRight = curRight:length() > 0.0001 and curRight:normalized() or vec3(1, 0, 0)
    local rotAxis = quatFromAxisAngle(curRight, math.rad(-15))
    local newOffset = rotAxis * offset
    local newCamPos = target + newOffset
    local fwd = (target - newCamPos):normalized()
    snapCameraView(target, fwd, vec3(0, 0, 1), newOffset:length())
    return true
  elseif preset == "orbitDown" then
    local target = getCameraTargetPivot()
    local camPos = vec3(core_camera.getPosition())
    local offset = camPos - target
    local curRight = core_camera.getQuat() * vec3(1, 0, 0)
    curRight.z = 0
    curRight = curRight:length() > 0.0001 and curRight:normalized() or vec3(1, 0, 0)
    local rotAxis = quatFromAxisAngle(curRight, math.rad(15))
    local newOffset = rotAxis * offset
    local newCamPos = target + newOffset
    local fwd = (target - newCamPos):normalized()
    snapCameraView(target, fwd, vec3(0, 0, 1), newOffset:length())
    return true
  end

  return false
end

local function updateWheelRotation()
  local selectedIds = editor.selection.object or {}
  local shiftHeld = editor.keyModifiers.shift
    and not editor.keyModifiers.alt
  local armed = shiftHeld
    and #selectedIds > 0
    and inputAvailable()
    and not activeModalOperator()
    and not nativeGizmo.isInteracting()
  local mouseWheel = im.GetIO().MouseWheel

  if st.wheelRotateActive then
    setWheelZoomBlocked(true)
    setModalInputBlocked(true)
    if not transformSession.selectionMatches() then
      clearWheelRotation(false)
      selectionModel.invalidateCache("wheelRotateCancel")
      setModalInputBlocked(false)
      return false, armed
    end
    if armed and mouseWheel ~= 0 then
      local stepDegrees = editor.keyModifiers.ctrl
        and 1
        or (cfg.rotateSnapEnabled[0] and cfg.rotateSnapSize[0] or 5)
      st.wheelRotateAngle = st.wheelRotateAngle + math.rad(stepDegrees) * mouseWheel
      transformSession.updateRotation(st.wheelRotatePivot, st.wheelRotateAxis, st.wheelRotateAngle)
      return true, true
    end
    if not shiftHeld then
      clearWheelRotation(true)
      selectionModel.invalidateCache("wheelRotateFinish")
      st.latestSelectionSnapshot = nil
      setModalInputBlocked(false)
      return false, armed
    end
    return true, true
  end

  if not armed or mouseWheel == 0 then return false, armed end
  local anchor = scenetree.findObjectById(selectedIds[#selectedIds])
  if not anchor or not transformSession.begin(anchor, {historyName = "EasySelectWheelRotate"}) then
    return false, armed
  end
  if editor.computeSelectionBBox then editor.computeSelectionBBox() end
  st.wheelRotateActive = true
  st.wheelRotateAngle = 0
  st.wheelRotateAxis = vec3(0, 0, 1)
  if cfg.defaultCoordinateMode[0] == 1 and anchor.getTransform then
    local localZ = vec3(anchor:getTransform():getColumn(2))
    if localZ:length() > 0.0001 then
      localZ:normalize()
      st.wheelRotateAxis = localZ
    end
  end
  st.wheelRotatePivot = vec3(editor.objectSelectionBBox:getCenter())
  selectionModel.releasePick()
  st.latestSelectionSnapshot = nil
  setWheelZoomBlocked(true)
  setModalInputBlocked(true)

  local stepDegrees = editor.keyModifiers.ctrl
    and 1
    or (cfg.rotateSnapEnabled[0] and cfg.rotateSnapSize[0] or 5)
  st.wheelRotateAngle = math.rad(stepDegrees) * mouseWheel
  transformSession.updateRotation(st.wheelRotatePivot, st.wheelRotateAxis, st.wheelRotateAngle)
  return true, true
end

local function updateNativeGizmo()
  if not st.nativeGizmoVisible or activeModalOperator() or transformSession.isActive() then
    return false, false
  end
  if not nativeGizmo.isInteracting() and editor.updateObjectSelectionAxisGizmo then
    editor.updateObjectSelectionAxisGizmo()
  end
  local drawn = nativeGizmo.draw({
    gridSnapEnabled = cfg.gridSnap[0],
    gridRelative = cfg.gridSnapMode[0] == 1,
    gridSize = cfg.gridSize[0],
    rotateSnapEnabled = cfg.rotateSnapEnabled[0],
    rotateSnapSize = cfg.rotateSnapSize[0]
  })
  local interacting = nativeGizmo.isInteracting()
  if interacting and st.nativeGizmoMode == editor.AxisGizmoMode_Scale then
    stats.invalidateVolume()
  end
  local finished, completion = nativeGizmo.consumeFinished()
  if completion then
    if completion.mode == editor.AxisGizmoMode_Translate then
      stats.recordOperation("transform", "native", completion.anchorDistance)
    elseif completion.mode == editor.AxisGizmoMode_Rotate then
      stats.recordOperation("rotate", "native")
    elseif completion.mode == editor.AxisGizmoMode_Scale then
      stats.recordOperation("scale", "native")
    end
  end
  if finished then
    selectionModel.invalidateCache("nativeGizmo")
    st.latestSelectionSnapshot = nil
    setModalInputBlocked(false)
  end
  return drawn, interacting
end

local function handleSelectionClick(nativeGizmoDrawn)
  if not im.IsMouseClicked(0) or nativeGizmoDrawn and editor.isAxisGizmoHovered() then return end
  local candidate = selectionModel.freezePick()
  local target = candidate and candidate.target or nil
  local hasSelectionModifier = editor.keyModifiers.ctrl or editor.keyModifiers.shift or editor.keyModifiers.alt
  if not target or hasSelectionModifier then
    selectCandidate(candidate)
    return
  end

  if not editor.isObjectSelected(target:getID()) then selectCandidate(candidate) end
  if not editor.isObjectSelected(target:getID()) or not transformSession.begin(target) then return end

  setModalInputBlocked(true)
  stopCameraMovement()
  st.latestSelectionSnapshot = nil
  st.dragPlaneZ = target:getPosition().z
  local camera = getCameraContext()
  if camera then
    local mouse = im.GetMousePos()
    st.dragMouseStart = im.ImVec2(mouse.x, mouse.y)
    st.dragScreenGroundStartPosition = vec3(target:getPosition())
    st.dragGroundRight = vec3(camera.right.x, camera.right.y, 0)
    st.dragGroundForward = vec3(camera.forward.x, camera.forward.y, 0)
    local rightLength = st.dragGroundRight:length()
    local forwardLength = st.dragGroundForward:length()
    st.dragGroundRight = rightLength > 0.0001 and st.dragGroundRight / rightLength or vec3(1, 0, 0)
    st.dragGroundForward = forwardLength > 0.0001 and st.dragGroundForward / forwardLength or vec3(0, 1, 0)
    local cameraDistance = (target:getPosition() - camera.pos):length()
    st.dragWorldPerPixel = 2 * math.max(cameraDistance, 1) * camera.halfTan / camera.height
  end

  local targetBox = target:getWorldBox()
  if validBox(targetBox) then
    st.dragBoxCenterOffset = targetBox:getCenter() - target:getPosition()
    st.dragBoxBottomCenterOffset = vec3(
      st.dragBoxCenterOffset.x,
      st.dragBoxCenterOffset.y,
      targetBox.minExtents.z - target:getPosition().z)
  end
  st.dragSurfaceFitData = surfaceFitDataForObject(target)

  if cfg.terrainSnapEnabled[0] and cfg.treatObjectsIndividually[0] then
    buildIndividualSnapData()
  else
    table.clear(st.dragIndividualData)
    table.clear(st.dragSurfaceFitSamples)
  end

  local point = placementPoint()
  local surfaceMode = cfg.surfacePlacementMode[0]
  if point
    and cfg.terrainSnapEnabled[0]
    and not cfg.treatObjectsIndividually[0]
    and isMultiPointSurfaceMode(surfaceMode) then
    point = fittedSurface(point.pos, transformOptions(), vec3(target:getPosition())) or point
  elseif point
    and cfg.terrainSnapEnabled[0]
    and not cfg.treatObjectsIndividually[0]
    and (surfaceMode == 1 or surfaceMode == 2) then
    point = fittedSingleReference(
      point,
      vec3(target:getPosition()),
      surfaceMode) or point
  end
  if point and #st.dragSurfaceFitSamples == 0 then setSurfaceFitSamples({point.pos}) end

  local verticalOffset = nil
  if cfg.terrainSnapEnabled[0] then
    if surfaceMode == 0 or surfaceMode == 6 then
      verticalOffset = 0
    elseif surfaceMode == 1 and st.dragBoxCenterOffset then
      verticalOffset = st.dragBoxCenterOffset.z
    elseif isBottomSurfaceMode(surfaceMode) and validBox(targetBox) then
      verticalOffset = targetBox.minExtents.z - target:getPosition().z
    end
  end
  local preserveHeight = not cfg.terrainSnapEnabled[0] or surfaceMode == 3
  if not point or not transformSession.setGrabSurface(point.pos, preserveHeight, verticalOffset) then
    endDirectTransform(false, "transformCancel")
    return
  end
  setWheelZoomBlocked(false)
end

local function updateFenceMode()
  if not fence.isModeActive() then return false end
  setWheelZoomBlocked(false)
  setModalInputBlocked(false)
  if st.nativeGizmoVisible then
    nativeGizmo.reset()
    st.nativeGizmoVisible = false
    st.nativeGizmoMode = nil
  end
  fence.update(inputAvailable())
  return true
end

function M.update()
  if not st.active then return false end
  if st.selectedTintNeedsRefresh then
    st.selectedTintNeedsRefresh = false
    worldEditorCppApi.setAxisGizmoHighlightSelectedMeshes(cfg.selectedTintEnabled[0])
  end
  syncCoordinateMode()
  if updateFenceMode() then return true end
  local modal = activeModalOperator()
  if modal then
    st.transformShortcutRequested = false
    st.rotateShortcutRequested = false
    st.scaleShortcutRequested = false
    setWheelZoomBlocked(true)
    setModalInputBlocked(true)
    stopCameraMovement()
    worldEditorCppApi.setHoveredObjectId(0)
    st.latestSelectionSnapshot = nil
    local result, completion
    if transformSession.selectionMatches() then
      result, completion = modal.operator.update(modalOperatorOptions(modal.id))
    else
      modal.operator.cancel()
      result = "cancel"
    end
    if modal.id == "scale" then stats.invalidateVolume() end
    selectionDebug.drawWorld(nil, {
      axisLengthScale = cfg.selectionGizmoLengthScale[0],
      axisLineWidth = cfg.selectionGizmoLineWidth[0],
      axisLocal = cfg.defaultCoordinateMode[0] == 1,
      debugSelectionText = cfg.debugEnabled[0],
      depthTest = cfg.boundsDepthTest[0],
      selectedDepthTest = cfg.selectedBoundsDepthTest[0],
      dragDepthTest = cfg.dragBoundsDepthTest[0],
      outlineMode = cfg.outlineMode[0],
      maxDiscoveryOutlines = cfg.maxDiscoveryOutlines[0],
      maxStackOutlines = cfg.maxStackOutlines[0],
      showSelectionAxes = false,
      selectedIds = editor.selection.object,
      draggingIds = modal.operator.getObjectIds(),
      draggingLabel = modal.label
    })
    if completion then
      if modal.id == "transform" then
        stats.recordOperation("transform", "g", completion.anchorDistance)
      elseif modal.id == "rotate" then
        stats.recordOperation("rotate", "r")
      elseif modal.id == "scale" then
        stats.recordOperation("scale", "s")
      end
    end
    if result == "confirm" or result == "cancel" then
      selectionModel.invalidateCache("modal" .. modal.id .. result)
      setWheelZoomBlocked(false)
      setModalInputBlocked(false)
    end
    return true
  end

  local directShortcutsAvailable = cfg.suppressCameraForGrs[0]
    and modalShortcutAvailable()
  local requested = {
    transform = st.transformShortcutRequested
      or directShortcutsAvailable and transformOperator.wantsBegin(),
    rotate = st.rotateShortcutRequested
      or directShortcutsAvailable and rotateOperator.wantsBegin(),
    scale = st.scaleShortcutRequested
      or directShortcutsAvailable and scaleOperator.wantsBegin()
  }
  st.transformShortcutRequested = false
  st.rotateShortcutRequested = false
  st.scaleShortcutRequested = false
  local requestedModal
  for _, entry in ipairs(modalOperators) do
    if requested[entry.id] then
      requestedModal = entry
      break
    end
  end
  if inputAvailable()
    and requestedModal
    and requestedModal.operator.begin({
      defaultLocal = cfg.defaultCoordinateMode[0] == 1
    }) then
    selectionModel.releasePick()
    st.latestSelectionSnapshot = nil
    setWheelZoomBlocked(true)
    setModalInputBlocked(true)
    return true
  end
  if requestedModal then setModalInputBlocked(false) end

  local wheelRotationActive, wheelRotationArmed = updateWheelRotation()
  if wheelRotationActive then return true end

  if updateNumpadPresets() then return true end

  if not im.IsMouseDown(0) then selectionModel.releasePick() end
  if updateTransformSession() then return true end

  local nativeGizmoDrawn, nativeGizmoInteracting = updateNativeGizmo()
  if nativeGizmoInteracting then
    setWheelZoomBlocked(true)
    setModalInputBlocked(true)
    worldEditorCppApi.setHoveredObjectId(0)
    st.latestSelectionSnapshot = nil
    return true
  end

  if not inputAvailable() then
    setWheelZoomBlocked(true)
    worldEditorCppApi.setHoveredObjectId(0)
    local diagnosticsSnapshot = (cfg.debugEnabled[0] or cfg.showDistanceRing[0] or cfg.showVolumeFilteredObjects[0])
      and {
        camera = getCameraContext(),
        filteredLarge = st.latestSelectionSnapshot and st.latestSelectionSnapshot.filteredLarge or {}
      }
      or nil
    selectionDebug.drawWorld(diagnosticsSnapshot, {
      axisLengthScale = cfg.selectionGizmoLengthScale[0],
      axisLineWidth = cfg.selectionGizmoLineWidth[0],
      axisLocal = cfg.defaultCoordinateMode[0] == 1,
      debugSelectionText = cfg.debugEnabled[0],
      debugEnabled = cfg.debugEnabled[0],
      depthTest = cfg.boundsDepthTest[0],
      selectedDepthTest = cfg.selectedBoundsDepthTest[0],
      dragDepthTest = cfg.dragBoundsDepthTest[0],
      outlineMode = cfg.outlineMode[0],
      maxDiscoveryOutlines = cfg.maxDiscoveryOutlines[0],
      maxStackOutlines = cfg.maxStackOutlines[0],
      showSelectionAxes = not nativeGizmoDrawn,
      showDistanceRing = cfg.showDistanceRing[0],
      maxDistance = cfg.maxPickDistance[0],
      showFilteredLarge = cfg.showVolumeFilteredObjects[0],
      selectedIds = editor.selection.object
    })
    return true
  end

  local discoveryPixels = cfg.discoveryRadius[0] * im.uiscale[0]
  local selectionTimer = hptimer()
  st.latestSelectionSnapshot = selectionModel.update({
    discoveryPixels = discoveryPixels,
    maxDistance = cfg.maxPickDistance[0],
    maxStackDistance = cfg.maxStackDistance[0],
    maxVolume = cfg.maxPickVolume[0],
    namePattern = ffi.string(cfg.patternFilter),
    ignorePattern = ffi.string(cfg.ignorePatternFilter),
    collectFilteredLarge = cfg.showVolumeFilteredObjects[0],
    preferUnselected = editor.keyModifiers.shift
      and not editor.keyModifiers.ctrl
      and not editor.keyModifiers.alt
      and editor.selection.object
      and not tableIsEmpty(editor.selection.object),
    cycleDeadZone = 6 * im.uiscale[0]
  })
  local mouseWheel = im.GetIO().MouseWheel
  local stackWheelActive = st.latestSelectionSnapshot.stackCount > 1
    and editor.keyModifiers.ctrl
  setWheelZoomBlocked(wheelRotationArmed or stackWheelActive)
  if stackWheelActive and mouseWheel ~= 0 then
    st.latestSelectionSnapshot = selectionModel.cycle(mouseWheel)
  end

  worldEditorCppApi.setHoveredObjectId(0)
  selectionDebug.drawWorld(st.latestSelectionSnapshot, {
    axisLengthScale = cfg.selectionGizmoLengthScale[0],
    axisLineWidth = cfg.selectionGizmoLineWidth[0],
    axisLocal = cfg.defaultCoordinateMode[0] == 1,
    debugSelectionText = cfg.debugEnabled[0],
    debugEnabled = cfg.debugEnabled[0],
    depthTest = cfg.boundsDepthTest[0],
    selectedDepthTest = cfg.selectedBoundsDepthTest[0],
    dragDepthTest = cfg.dragBoundsDepthTest[0],
    outlineMode = cfg.outlineMode[0],
    maxDiscoveryOutlines = cfg.maxDiscoveryOutlines[0],
    maxStackOutlines = cfg.maxStackOutlines[0],
    showSelectionAxes = not nativeGizmoDrawn,
    showDistanceRing = cfg.showDistanceRing[0],
    maxDistance = cfg.maxPickDistance[0],
    showFilteredLarge = cfg.showVolumeFilteredObjects[0],
    selectedIds = editor.selection.object
  })
  st.performanceFrameId = st.performanceFrameId + 1
  st.latestSelectionSnapshot.performanceFrameId = st.performanceFrameId
  st.latestSelectionSnapshot.performanceTime = selectionTimer:stopAndReset()

  handleSelectionClick(nativeGizmoDrawn)
  return true
end

local function drawHint(binding, description)
  editor.uiTextColoredWithFont(uiTheme.hintBindingColor, binding, "cairo_bold")
  im.SameLine()
  im.TextWrapped(description)
end

local function drawHintsWorkspace()
  im.HeaderText("General")
  drawHint("F", "Center the camera on the object under the cursor, or on the current selection")
  drawHint("4", "Switch between world and local axes")
  im.HeaderText("Mouse Controls")
  drawHint("Ctrl + Mouse Wheel", "Cycle through overlapping objects under the cursor")
  drawHint("Shift + Mouse Wheel", "Rotate the selection around the current world/local Z axis")
  drawHint("Shift + Ctrl + Mouse Wheel", "Rotate around the current Z axis in precise 1 degree steps")
  im.HeaderText("Blender-Style Editing")
  drawHint("G", "Move the object; press X, Y, or Z to constrain the transform to an axis")
  drawHint("R", "Rotate the selection around the view axis; use X/Y/Z to choose an axis, or type an angle")
  drawHint("S", "Scale uniformly; use X/Y/Z for one axis, Shift + X/Y/Z for the other two, or type a factor")
  drawHint("X/Y/Z twice", "Switch the active constraint between world and local axes")
  drawHint("Left Click / Enter", "Apply the transform")
  drawHint("Right Click / Escape", "Cancel the transform")
end

function M.drawWorkspace()
  syncCoordinateMode()
  if not im.BeginTabBar("###ezObjectSelectWorkspaceTabs") then return end
  if im.BeginTabItem("Selection###ezSelectSelectionTab") then
  im.HeaderText("Snapping")
  im.Checkbox("Terrain snap##terrainSnap", cfg.terrainSnapEnabled)
  if not cfg.terrainSnapEnabled[0] then im.BeginDisabled() end
  im.TextUnformatted("Surface source")
  im.RadioButton2("Terrain##surfaceTerrain", cfg.placementMode, im.Int(0))
  im.SameLine()
  im.RadioButton2("Raycast##surfaceRaycast", cfg.placementMode, im.Int(1))
  if cfg.placementMode[0] ~= 1 then im.BeginDisabled() end
  im.SliderFloat("Raycast vertical offset##raycastVerticalOffset", cfg.raycastVerticalOffset, 0.1, 20, "%.1f m")
  im.tooltip("Raises the projected cursor position before casting vertically downward")
  if cfg.placementMode[0] ~= 1 then im.EndDisabled() end
  im.Checkbox("Treat objects individually##individualObjects", cfg.treatObjectsIndividually)

  im.Separator()
  local multiPointMode = isMultiPointSurfaceMode(cfg.surfacePlacementMode[0])
  if multiPointMode then im.BeginDisabled() end
  im.Checkbox("Follow surface slope##followSurfaceSlope", cfg.followRotation)
  im.tooltip("Preserve heading while aligning pitch and roll to the sampled surface")
  if multiPointMode then im.EndDisabled() end

  im.TextUnformatted("Surface placement")
  im.SetNextItemWidth(190 * im.uiscale[0])
  if im.Combo1(
    "##surfacePlacement",
    cfg.surfacePlacementMode,
    cfg.surfacePlacementItems)
    and isMultiPointSurfaceMode(cfg.surfacePlacementMode[0]) then
    cfg.followRotation[0] = true
  end
  im.tooltip(
    "Long-edge samples the two long lower edges; Short-edge samples the two short lower edges; "
    .. "Short-edge at origin Z projects the short-edge midpoints to local Z=0")
  im.SameLine()
  im.Checkbox("Show fit points##showSurfaceFitPoints", cfg.showSurfaceFitPoints)
  im.tooltip("Draw the sampled surface points while dragging")
  if not cfg.terrainSnapEnabled[0] then im.EndDisabled() end

  im.Separator()
  im.Checkbox("Grid snap##gridSnap", cfg.gridSnap)
  im.SameLine()
  im.SetNextItemWidth(100 * im.uiscale[0])
  if im.Combo1("##gridSize", cfg.gridPresetIndex, cfg.gridPresetItems) then
    cfg.gridSize[0] = tonumber(cfg.gridPresetValues[cfg.gridPresetIndex[0] + 1])
  end
  im.SameLine()
  im.RadioButton2("Absolute##gridReference", cfg.gridSnapMode, im.Int(0))
  im.SameLine()
  im.RadioButton2("Relative##gridReference", cfg.gridSnapMode, im.Int(1))
  im.tooltip("Absolute uses the world grid; relative measures snapped movement from the drag start")

  im.Separator()
  im.Checkbox("Rotate snap##rotateSnap", cfg.rotateSnapEnabled)
  im.SameLine()
  im.SetNextItemWidth(100 * im.uiscale[0])
  if im.Combo1("##rotateSnapSize", cfg.rotatePresetIndex, cfg.rotatePresetItems) then
    cfg.rotateSnapSize[0] = tonumber(cfg.rotatePresetValues[cfg.rotatePresetIndex[0] + 1])
  end
  im.SameLine()
  im.RadioButton2("Absolute##rotateReference", cfg.rotateSnapMode, im.Int(0))
  im.SameLine()
  im.RadioButton2("Relative##rotateReference", cfg.rotateSnapMode, im.Int(1))
  im.tooltip("Absolute uses world yaw; relative uses the starting heading as zero")

  im.HeaderText("Dragging")
  im.RadioButton2("Raycast##dragProjectionRay", cfg.dragProjectionMode, im.Int(0))
  im.SameLine()
  im.RadioButton2("Screen##dragProjectionGround", cfg.dragProjectionMode, im.Int(1))
  im.tooltip("Raycast uses a raycast.\n\nScreen maps mouse movement onto the ground plane.\nThis is useful for low-angle or close-up edits where Raycast doesn't work well.")

  im.Separator()
  im.HeaderText("Filtering")
  drawPatternInput("Pattern", "pattern", cfg.patternFilter, cfg.patternMru)
  drawPatternInput("Ignore Pattern", "ignorePattern", cfg.ignorePatternFilter, cfg.ignorePatternMru)

  im.Separator()
  im.TextWrapped(
    "Easy Select uses the View > Visualization Settings... Selectable tab to limit which object types can be selected.")
  cameraBookmarks.draw()
  im.Separator()
  im.HeaderText("Tools")
  local resetRotationDisabled = not editor.selection.object
    or tableIsEmpty(editor.selection.object)
    or transformSession.isActive()
  if resetRotationDisabled then im.BeginDisabled() end
  if im.Button("Reset rotation##resetRotation") and transformSession.resetRotation(editor.selection.object) then
    selectionModel.invalidateCache("resetRotation")
    stats.invalidateVolume()
  end
  if resetRotationDisabled then im.EndDisabled() end
  im.tooltip("Remove pitch and roll while preserving heading, position, and scale")
  im.SameLine()
  if transformSession.isActive() then im.BeginDisabled() end
  if im.Button("Clear Cache##clearCache") then resetAllSelectionState() end
  if transformSession.isActive() then im.EndDisabled() end
  im.tooltip("Clear the internal Easy Select cache.")
  stats.draw(editor.selection.object)
    im.EndTabItem()
  end
  if im.BeginTabItem("Hints###ezSelectHintsTab") then
    drawHintsWorkspace()
    im.EndTabItem()
  end
  if im.BeginTabItem("Fence###ezSelectFenceTab") then
    fence.drawWorkspace({
      canEnter = not activeModalOperator()
        and not transformSession.isActive()
        and not nativeGizmo.isInteracting()
    })
    im.EndTabItem()
  end
  im.EndTabBar()
end

local function outlineModeFromString(value)
  if value == 1 or value == "1" or value == "Bounding box" then return 1 end
  return 0
end

local function labelPlacementModeFromString(value)
  if value == 0 or value == "0" or value == "Object top" then return 0 end
  return 1
end

local function drawPrefDefaultButton(item)
  im.SameLine()
  local pad = im.GetStyle().FramePadding
  local btnSize = im.ImVec2(im.CalcTextSize("o").x + pad.x * 2, 0)
  if im.Button("o##reset_" .. item.name, btnSize) then
    editor.preferencesRegistry:resetItemToDefault(item.path)
  end
  im.tooltip("Reset to default (" .. tostring(item.defaultValue) .. ")")
end

local function pushPrefWidgetWidth()
  local pad = im.GetStyle().FramePadding
  local spacing = im.GetStyle().ItemSpacing
  local btnWidth = im.CalcTextSize("o").x + pad.x * 2 + spacing.x
  local avail = im.GetContentRegionAvailWidth()
  im.PushItemWidth(math.max(avail - btnWidth, 40))
end

function prefUi.debug(_, _, item)
  if im.Checkbox("##pref_debug", cfg.debugEnabled) then
    editor.setPreference(item.path, cfg.debugEnabled[0])
  end
  drawPrefDefaultButton(item)
end

function prefUi.showHoverRing(_, _, item)
  if im.Checkbox("##pref_showHoverRing", cfg.showHoverRing) then
    editor.setPreference(item.path, cfg.showHoverRing[0])
  end
  drawPrefDefaultButton(item)
end

function prefUi.discoveryRadius(_, _, item)
  pushPrefWidgetWidth()
  if im.SliderInt("##pref_discoveryRadius", cfg.discoveryRadius, 8, 500, "%d px") then
    editor.setPreference(item.path, cfg.discoveryRadius[0])
  end
  im.PopItemWidth()
  drawPrefDefaultButton(item)
end

function prefUi.maxDiscoveryOutlines(_, _, item)
  pushPrefWidgetWidth()
  if im.SliderInt("##pref_maxDiscoveryOutlines", cfg.maxDiscoveryOutlines, 0, 50) then
    editor.setPreference(item.path, cfg.maxDiscoveryOutlines[0])
  end
  im.PopItemWidth()
  drawPrefDefaultButton(item)
end

function prefUi.maxStackOutlines(_, _, item)
  pushPrefWidgetWidth()
  if im.SliderInt("##pref_maxStackOutlines", cfg.maxStackOutlines, 1, 50) then
    editor.setPreference(item.path, cfg.maxStackOutlines[0])
  end
  im.PopItemWidth()
  drawPrefDefaultButton(item)
end

function prefUi.showDistanceRing(_, _, item)
  if im.Checkbox("##pref_showDistanceRing", cfg.showDistanceRing) then
    editor.setPreference(item.path, cfg.showDistanceRing[0])
  end
  drawPrefDefaultButton(item)
end

function prefUi.maxPickDistance(_, _, item)
  pushPrefWidgetWidth()
  if im.SliderFloat("##pref_maxPickDistance", cfg.maxPickDistance, 10, 500, "%.0f m") then
    editor.setPreference(item.path, cfg.maxPickDistance[0])
  end
  im.PopItemWidth()
  drawPrefDefaultButton(item)
end

function prefUi.showVolumeFilteredObjects(_, _, item)
  if im.Checkbox("##pref_showVolumeFilteredObjects", cfg.showVolumeFilteredObjects) then
    editor.setPreference(item.path, cfg.showVolumeFilteredObjects[0])
  end
  drawPrefDefaultButton(item)
end

function prefUi.maxPickVolume(_, _, item)
  pushPrefWidgetWidth()
  if im.SliderFloat("##pref_maxPickVolume", cfg.maxPickVolume, 1000, 100000000000, "%.0f m^3", im.SliderFlags_Logarithmic) then
    editor.setPreference(item.path, cfg.maxPickVolume[0])
  end
  im.PopItemWidth()
  drawPrefDefaultButton(item)
end

function prefUi.maxStackDistance(_, _, item)
  pushPrefWidgetWidth()
  if im.SliderFloat("##pref_maxStackDistance", cfg.maxStackDistance, 10, 1000, "%.0f m") then
    editor.setPreference(item.path, cfg.maxStackDistance[0])
  end
  im.PopItemWidth()
  drawPrefDefaultButton(item)
end

function prefUi.selectedTintEnabled(_, _, item)
  if im.Checkbox("##pref_selectedTintEnabled", cfg.selectedTintEnabled) then
    editor.setPreference(item.path, cfg.selectedTintEnabled[0])
  end
  drawPrefDefaultButton(item)
end

function prefUi.outlineMode(_, _, item)
  local changed = false
  if im.RadioButton2("Outline##pref_outlineMode0", cfg.outlineMode, im.Int(0)) then
    changed = true
  end
  im.SameLine()
  if im.RadioButton2("Bounding box##pref_outlineMode1", cfg.outlineMode, im.Int(1)) then
    changed = true
  end
  if changed then
    editor.setPreference(item.path, cfg.outlineMode[0] == 1 and "Bounding box" or "Outline")
  end
  drawPrefDefaultButton(item)
end

function prefUi.boundsDepthTest(_, _, item)
  local disabled = cfg.outlineMode[0] ~= 1
  if disabled then im.BeginDisabled() end
  if im.Checkbox("##pref_boundsDepthTest", cfg.boundsDepthTest) then
    editor.setPreference(item.path, cfg.boundsDepthTest[0])
  end
  drawPrefDefaultButton(item)
  if disabled then im.EndDisabled() end
end

function prefUi.selectedBoundsDepthTest(_, _, item)
  local disabled = cfg.outlineMode[0] ~= 1
  if disabled then im.BeginDisabled() end
  if im.Checkbox("##pref_selectedBoundsDepthTest", cfg.selectedBoundsDepthTest) then
    editor.setPreference(item.path, cfg.selectedBoundsDepthTest[0])
  end
  drawPrefDefaultButton(item)
  if disabled then im.EndDisabled() end
end

function prefUi.dragBoundsDepthTest(_, _, item)
  local disabled = cfg.outlineMode[0] ~= 1
  if disabled then im.BeginDisabled() end
  if im.Checkbox("##pref_dragBoundsDepthTest", cfg.dragBoundsDepthTest) then
    editor.setPreference(item.path, cfg.dragBoundsDepthTest[0])
  end
  drawPrefDefaultButton(item)
  if disabled then im.EndDisabled() end
end

function prefUi.labelPlacementMode(_, _, item)
  local changed = false
  if im.RadioButton2("Object top##pref_labelPlacementMode0", cfg.labelPlacementMode, im.Int(0)) then
    changed = true
  end
  im.SameLine()
  if im.RadioButton2("Follow mouse##pref_labelPlacementMode1", cfg.labelPlacementMode, im.Int(1)) then
    changed = true
  end
  if changed then
    editor.setPreference(item.path, cfg.labelPlacementMode[0] == 0 and "Object top" or "Follow mouse")
  end
  drawPrefDefaultButton(item)
end

function prefUi.showMoveConstraintPlane(_, _, item)
  if im.Checkbox("##pref_showMoveConstraintPlane", cfg.showMoveConstraintPlane) then
    editor.setPreference(item.path, cfg.showMoveConstraintPlane[0])
  end
  drawPrefDefaultButton(item)
end

function prefUi.clipMoveConstraintPlane(_, _, item)
  local disabled = not cfg.showMoveConstraintPlane[0]
  if disabled then im.BeginDisabled() end
  if im.Checkbox("##pref_clipMoveConstraintPlane", cfg.clipMoveConstraintPlane) then
    editor.setPreference(item.path, cfg.clipMoveConstraintPlane[0])
  end
  drawPrefDefaultButton(item)
  if disabled then im.EndDisabled() end
end

function prefUi.selectionGizmoLengthScale(_, _, item)
  pushPrefWidgetWidth()
  if im.SliderFloat("##pref_selectionGizmoLengthScale", cfg.selectionGizmoLengthScale, 0.25, 4, "%.2fx") then
    editor.setPreference(item.path, cfg.selectionGizmoLengthScale[0])
  end
  im.PopItemWidth()
  drawPrefDefaultButton(item)
end

function prefUi.selectionGizmoLineWidth(_, _, item)
  pushPrefWidgetWidth()
  if im.SliderFloat("##pref_selectionGizmoLineWidth", cfg.selectionGizmoLineWidth, 1, 10, "%.1f px") then
    editor.setPreference(item.path, cfg.selectionGizmoLineWidth[0])
  end
  im.PopItemWidth()
  drawPrefDefaultButton(item)
end

function prefUi.showOrientationGizmo(_, _, item)
  if im.Checkbox("##pref_showOrientationGizmo", cfg.showOrientationGizmo) then
    editor.setPreference(item.path, cfg.showOrientationGizmo[0])
  end
  drawPrefDefaultButton(item)
end

function prefUi.orientationGizmoTopOffset(_, _, item)
  local disabled = not cfg.showOrientationGizmo[0]
  if disabled then im.BeginDisabled() end
  pushPrefWidgetWidth()
  if im.SliderInt("##pref_orientationGizmoTopOffset", cfg.orientationGizmoTopOffset, 0, 500, "%d px") then
    editor.setPreference(item.path, cfg.orientationGizmoTopOffset[0])
  end
  im.PopItemWidth()
  drawPrefDefaultButton(item)
  if disabled then im.EndDisabled() end
end

function prefUi.orientationGizmoRightOffset(_, _, item)
  local disabled = not cfg.showOrientationGizmo[0]
  if disabled then im.BeginDisabled() end
  pushPrefWidgetWidth()
  if im.SliderInt("##pref_orientationGizmoRightOffset", cfg.orientationGizmoRightOffset, 0, 500, "%d px") then
    editor.setPreference(item.path, cfg.orientationGizmoRightOffset[0])
  end
  im.PopItemWidth()
  drawPrefDefaultButton(item)
  if disabled then im.EndDisabled() end
end

function prefUi.suppressCameraForGrs(_, _, item)
  if im.Checkbox("##pref_suppressCameraForGrs", cfg.suppressCameraForGrs) then
    editor.setPreference(item.path, cfg.suppressCameraForGrs[0])
  end
  drawPrefDefaultButton(item)
end

local function numpadModeFromString(value)
  if value == "blender" or value == 1 or value == "1" then return 1 end
  return 0
end

function prefUi.numpadMode(_, _, item)
  local changed = false
  if im.RadioButton2("Numpad standard (rotate camera)##pref_numpadStandard", cfg.numpadMode, im.Int(0)) then
    changed = true
  end
  if im.RadioButton2("Numpad camera presets (Blender style views)##pref_numpadBlender", cfg.numpadMode, im.Int(1)) then
    changed = true
  end
  if changed then
    editor.setPreference(item.path, cfg.numpadMode[0] == 1 and "blender" or "standard")
  end
  drawPrefDefaultButton(item)
end

local function loadPreferences()
  if not editor or not editor.getPreference then return end

  local val

  val = editor.getPreference("ezObjectSelect.general.debug")
  if val ~= nil then cfg.debugEnabled[0] = val == true end

  val = editor.getPreference("ezObjectSelect.selection.showHoverRing")
  if val ~= nil then cfg.showHoverRing[0] = val == true end
  val = editor.getPreference("ezObjectSelect.selection.discoveryRadius")
  if val ~= nil then cfg.discoveryRadius[0] = math.floor(val) end
  val = editor.getPreference("ezObjectSelect.selection.maxDiscoveryOutlines")
  if val ~= nil then cfg.maxDiscoveryOutlines[0] = math.floor(val) end
  val = editor.getPreference("ezObjectSelect.selection.maxStackOutlines")
  if val ~= nil then cfg.maxStackOutlines[0] = math.floor(val) end
  val = editor.getPreference("ezObjectSelect.selection.showDistanceRing")
  if val ~= nil then cfg.showDistanceRing[0] = val == true end
  val = editor.getPreference("ezObjectSelect.selection.maxPickDistance")
  if val ~= nil then cfg.maxPickDistance[0] = tonumber(val) or cfg.maxPickDistance[0] end
  val = editor.getPreference("ezObjectSelect.selection.showVolumeFilteredObjects")
  if val ~= nil then cfg.showVolumeFilteredObjects[0] = val == true end
  val = editor.getPreference("ezObjectSelect.selection.maxPickVolume")
  if val ~= nil then cfg.maxPickVolume[0] = tonumber(val) or cfg.maxPickVolume[0] end
  val = editor.getPreference("ezObjectSelect.selection.maxStackDistance")
  if val ~= nil then cfg.maxStackDistance[0] = tonumber(val) or cfg.maxStackDistance[0] end

  val = editor.getPreference("ezObjectSelect.outlines.selectedTintEnabled")
  if val ~= nil then
    cfg.selectedTintEnabled[0] = val == true
    if st.active then
      worldEditorCppApi.setAxisGizmoHighlightSelectedMeshes(cfg.selectedTintEnabled[0])
    end
  end
  val = editor.getPreference("ezObjectSelect.outlines.outlineMode")
  if val ~= nil then cfg.outlineMode[0] = outlineModeFromString(val) end
  val = editor.getPreference("ezObjectSelect.outlines.boundsDepthTest")
  if val ~= nil then cfg.boundsDepthTest[0] = val == true end
  val = editor.getPreference("ezObjectSelect.outlines.selectedBoundsDepthTest")
  if val ~= nil then cfg.selectedBoundsDepthTest[0] = val == true end
  val = editor.getPreference("ezObjectSelect.outlines.dragBoundsDepthTest")
  if val ~= nil then cfg.dragBoundsDepthTest[0] = val == true end
  val = editor.getPreference("ezObjectSelect.outlines.labelPlacementMode")
  if val ~= nil then cfg.labelPlacementMode[0] = labelPlacementModeFromString(val) end

  val = editor.getPreference("ezObjectSelect.gTransform.showMoveConstraintPlane")
  if val ~= nil then cfg.showMoveConstraintPlane[0] = val == true end
  val = editor.getPreference("ezObjectSelect.gTransform.clipMoveConstraintPlane")
  if val ~= nil then cfg.clipMoveConstraintPlane[0] = val == true end

  val = editor.getPreference("ezObjectSelect.selectedOriginGizmo.selectionGizmoLengthScale")
  if val ~= nil then cfg.selectionGizmoLengthScale[0] = tonumber(val) or cfg.selectionGizmoLengthScale[0] end
  val = editor.getPreference("ezObjectSelect.selectedOriginGizmo.selectionGizmoLineWidth")
  if val ~= nil then cfg.selectionGizmoLineWidth[0] = tonumber(val) or cfg.selectionGizmoLineWidth[0] end

  val = editor.getPreference("ezObjectSelect.viewportOrientation.showOrientationGizmo")
  if val ~= nil then cfg.showOrientationGizmo[0] = val == true end
  val = editor.getPreference("ezObjectSelect.viewportOrientation.orientationGizmoTopOffset")
  if val ~= nil then cfg.orientationGizmoTopOffset[0] = math.floor(val) end
  val = editor.getPreference("ezObjectSelect.viewportOrientation.orientationGizmoRightOffset")
  if val ~= nil then cfg.orientationGizmoRightOffset[0] = math.floor(val) end

  val = editor.getPreference("ezObjectSelect.bindings.suppressCameraForGrs")
  if val ~= nil then cfg.suppressCameraForGrs[0] = val == true end

  val = editor.getPreference("ezObjectSelect.bindings.numpadMode")
  if val ~= nil then cfg.numpadMode[0] = numpadModeFromString(val) end
end

function M.onEditorPreferenceValueChanged(path, value)
  if path == "ezObjectSelect.general.debug" then
    cfg.debugEnabled[0] = value == true
  elseif path == "ezObjectSelect.selection.showHoverRing" then
    cfg.showHoverRing[0] = value == true
  elseif path == "ezObjectSelect.selection.discoveryRadius" then
    cfg.discoveryRadius[0] = math.floor(value)
  elseif path == "ezObjectSelect.selection.maxDiscoveryOutlines" then
    cfg.maxDiscoveryOutlines[0] = math.floor(value)
  elseif path == "ezObjectSelect.selection.maxStackOutlines" then
    cfg.maxStackOutlines[0] = math.floor(value)
  elseif path == "ezObjectSelect.selection.showDistanceRing" then
    cfg.showDistanceRing[0] = value == true
  elseif path == "ezObjectSelect.selection.maxPickDistance" then
    cfg.maxPickDistance[0] = tonumber(value) or cfg.maxPickDistance[0]
  elseif path == "ezObjectSelect.selection.showVolumeFilteredObjects" then
    cfg.showVolumeFilteredObjects[0] = value == true
  elseif path == "ezObjectSelect.selection.maxPickVolume" then
    cfg.maxPickVolume[0] = tonumber(value) or cfg.maxPickVolume[0]
  elseif path == "ezObjectSelect.selection.maxStackDistance" then
    cfg.maxStackDistance[0] = tonumber(value) or cfg.maxStackDistance[0]
  elseif path == "ezObjectSelect.outlines.selectedTintEnabled" then
    cfg.selectedTintEnabled[0] = value == true
    if st.active then
      worldEditorCppApi.setAxisGizmoHighlightSelectedMeshes(cfg.selectedTintEnabled[0])
    end
  elseif path == "ezObjectSelect.outlines.outlineMode" then
    cfg.outlineMode[0] = outlineModeFromString(value)
  elseif path == "ezObjectSelect.outlines.boundsDepthTest" then
    cfg.boundsDepthTest[0] = value == true
  elseif path == "ezObjectSelect.outlines.selectedBoundsDepthTest" then
    cfg.selectedBoundsDepthTest[0] = value == true
  elseif path == "ezObjectSelect.outlines.dragBoundsDepthTest" then
    cfg.dragBoundsDepthTest[0] = value == true
  elseif path == "ezObjectSelect.outlines.labelPlacementMode" then
    cfg.labelPlacementMode[0] = labelPlacementModeFromString(value)
  elseif path == "ezObjectSelect.gTransform.showMoveConstraintPlane" then
    cfg.showMoveConstraintPlane[0] = value == true
  elseif path == "ezObjectSelect.gTransform.clipMoveConstraintPlane" then
    cfg.clipMoveConstraintPlane[0] = value == true
  elseif path == "ezObjectSelect.selectedOriginGizmo.selectionGizmoLengthScale" then
    cfg.selectionGizmoLengthScale[0] = tonumber(value) or cfg.selectionGizmoLengthScale[0]
  elseif path == "ezObjectSelect.selectedOriginGizmo.selectionGizmoLineWidth" then
    cfg.selectionGizmoLineWidth[0] = tonumber(value) or cfg.selectionGizmoLineWidth[0]
  elseif path == "ezObjectSelect.viewportOrientation.showOrientationGizmo" then
    cfg.showOrientationGizmo[0] = value == true
  elseif path == "ezObjectSelect.viewportOrientation.orientationGizmoTopOffset" then
    cfg.orientationGizmoTopOffset[0] = math.floor(value)
  elseif path == "ezObjectSelect.viewportOrientation.orientationGizmoRightOffset" then
    cfg.orientationGizmoRightOffset[0] = math.floor(value)
  elseif path == "ezObjectSelect.bindings.suppressCameraForGrs" then
    cfg.suppressCameraForGrs[0] = value == true
    if st.active then
      setBlenderBindingsEnabled(cfg.suppressCameraForGrs[0])
      setCameraMovementBlocked(cfg.suppressCameraForGrs[0])
    end
  elseif path == "ezObjectSelect.bindings.numpadMode" then
    cfg.numpadMode[0] = numpadModeFromString(value)
    if st.active then
      setNumpadActionsBlocked(cfg.numpadMode[0] == 1)
      if cfg.numpadMode[0] == 0 and st.orthoActive then
        setOrthoEnabled(false)
      end
    end
  end
end

function M.onEditorRegisterPreferences(prefsRegistry)
  prefsRegistry:registerCategory("ezObjectSelect", "Easy Select")

  prefsRegistry:registerSubCategory("ezObjectSelect", "general", "General", {
    {debug = {"bool", false, "Show selection diagnostics and detailed viewport labels", "Debug", nil, nil, nil, nil, prefUi.debug}}
  })

  prefsRegistry:registerSubCategory("ezObjectSelect", "selection", "Selection", {
    {showHoverRing = {"bool", true, "Show the cursor-centered discovery ring and object guide lines", "Show Hover Ring", nil, nil, nil, nil, prefUi.showHoverRing}},
    {discoveryRadius = {"int", 100, "Screen-space radius used to discover nearby objects", "Hover Radius", 8, 500, nil, nil, prefUi.discoveryRadius}},
    {maxDiscoveryOutlines = {"int", 5, "Maximum nearby object outlines shown before results are condensed", "Max Discovery Outlines", 0, 50, nil, nil, prefUi.maxDiscoveryOutlines}},
    {maxStackOutlines = {"int", 5, "Maximum overlapping stack candidate outlines shown", "Max Stack Outlines", 1, 50, nil, nil, prefUi.maxStackOutlines}},
    {showDistanceRing = {"bool", true, "Show the maximum pick-distance boundary in the viewport", "Show Pick-Distance Ring", nil, nil, nil, nil, prefUi.showDistanceRing}},
    {maxPickDistance = {"float", 150.0, "Maximum distance from the camera focus point to a selectable object", "Max Pick Distance", 10.0, 500.0, nil, nil, prefUi.maxPickDistance}},
    {showVolumeFilteredObjects = {"bool", false, "Outline objects excluded by the volume limit in red", "Show Volume-Filtered Objects", nil, nil, nil, nil, prefUi.showVolumeFilteredObjects}},
    {maxPickVolume = {"float", 500000.0, "Ignore objects whose oriented bounding-box volume exceeds this limit", "Max Bounding-Box Volume", 1000.0, 100000000000.0, nil, nil, prefUi.maxPickVolume}},
    {maxStackDistance = {"float", 200.0, "Beyond this camera distance, hover resolves only the best object", "Max Stack Distance", 10.0, 1000.0, nil, nil, prefUi.maxStackDistance}}
  })

  prefsRegistry:registerSubCategory("ezObjectSelect", "outlines", "Outlines", {
    {selectedTintEnabled = {"bool", false, "Tint selected meshes and fill their Easy Select outlines", "Tint Selected Objects", nil, nil, nil, nil, prefUi.selectedTintEnabled}},
    {outlineMode = {"string", "Outline", "Outline style", "Outline Style", nil, nil, nil, nil, prefUi.outlineMode}},
    {boundsDepthTest = {"bool", true, "Hide hover-box segments behind scene geometry", "Clip Hover Bounding Boxes", nil, nil, nil, nil, prefUi.boundsDepthTest}},
    {selectedBoundsDepthTest = {"bool", true, "Hide selected-box segments behind scene geometry", "Clip Selected Bounding Boxes", nil, nil, nil, nil, prefUi.selectedBoundsDepthTest}},
    {dragBoundsDepthTest = {"bool", true, "Hide drag-box segments behind scene geometry", "Clip Drag Bounding Boxes", nil, nil, nil, nil, prefUi.dragBoundsDepthTest}},
    {labelPlacementMode = {"string", "Follow mouse", "2D label position", "2D Label Position", nil, nil, nil, nil, prefUi.labelPlacementMode}}
  })

  prefsRegistry:registerSubCategory("ezObjectSelect", "gTransform", "G Transform", {
    {showMoveConstraintPlane = {"bool", true, "Draw the movement plane for unconstrained and planar G transforms", "Draw Gizmo Plane", nil, nil, nil, nil, prefUi.showMoveConstraintPlane}},
    {clipMoveConstraintPlane = {"bool", true, "Hide grid lines behind scene geometry", "Clip Gizmo Plane", nil, nil, nil, nil, prefUi.clipMoveConstraintPlane}}
  })

  prefsRegistry:registerSubCategory("ezObjectSelect", "selectedOriginGizmo", "Selected Origin Gizmo", {
    {selectionGizmoLengthScale = {"float", 2.0, "Line length multiplier for selected object origin gizmo", "Line Length", 0.25, 4.0, nil, nil, prefUi.selectionGizmoLengthScale}},
    {selectionGizmoLineWidth = {"float", 4.0, "Line width for selected object origin gizmo", "Line Width", 1.0, 10.0, nil, nil, prefUi.selectionGizmoLineWidth}}
  })

  prefsRegistry:registerSubCategory("ezObjectSelect", "viewportOrientation", "Viewport Orientation", {
    {showOrientationGizmo = {"bool", true, "Show a fixed world/local axis reference in the viewport", "Show Orientation Gizmo", nil, nil, nil, nil, prefUi.showOrientationGizmo}},
    {orientationGizmoTopOffset = {"int", 140, "Top offset in pixels from the viewport top-right corner", "Top Offset", 0, 500, nil, nil, prefUi.orientationGizmoTopOffset}},
    {orientationGizmoRightOffset = {"int", 75, "Right offset in pixels from the viewport top-right corner", "Right Offset", 0, 500, nil, nil, prefUi.orientationGizmoRightOffset}}
  })

  prefsRegistry:registerSubCategory("ezObjectSelect", "bindings", "Bindings", {
    {suppressCameraForGrs = {"bool", false, "Reserve G, R, and S for Easy Select's modal Move, Rotate, and Scale tools. While enabled, normal WASD camera movement is suppressed so S cannot move the camera when starting a scale.", "Use Blender-style bindings", nil, nil, nil, nil, prefUi.suppressCameraForGrs}},
    {numpadMode = {"string", "standard", "Choose numpad behavior in Easy Select mode", "Numpad Behavior", nil, nil, nil, nil, prefUi.numpadMode}}
  })
end

M.loadPreferences = loadPreferences

return M
