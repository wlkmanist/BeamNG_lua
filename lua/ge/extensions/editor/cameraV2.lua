-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Camera V2 provides an alternative set of mouse controls for the existing free
-- camera. To avoid destabilizing the established camera implementation, inputs
-- are routed here only when Camera V2 is enabled; otherwise the stock input path
-- remains unchanged.

local M = {}

local registry = require("core/cameraControllerRegistry")
local controller = require("editor/cameraV2/controller")
local validation = require("editor/cameraV2/validation")
local controllerId = "editor.cameraV2"
local controllerPreferencePath = "camera.general.activeCamera"
local preferencePrefix = "camera.cameraV2."
local debugWindowName = "cameraV2Debug"
local cursorRayDistance = 100000
local referenceElevationThreshold = 1500
local registered = false
local windowRegistered = false
local temporaryEnabled = false
local debugWindowBg = ui_imgui.ImVec4(0.04, 0.18, 0.08, 0.96)
local debugTitleBg = ui_imgui.ImVec4(0.06, 0.28, 0.12, 1)
local debugTitleActiveBg = ui_imgui.ImVec4(0.08, 0.42, 0.17, 1)
local debugBorder = ui_imgui.ImVec4(0.2, 0.85, 0.35, 1)

local function drawMouseLayoutPreference(_, _, customData)
  local swapped = editor.getPreference(customData.path) == true
  if ui_imgui.RadioButton1(
    "Middle pan / Right orbit##cameraV2MouseLayout",
    not swapped) then
    editor.setPreference(customData.path, false)
  end
  if ui_imgui.RadioButton1(
    "Right pan / Middle orbit##cameraV2MouseLayout",
    swapped) then
    editor.setPreference(customData.path, true)
  end
end

local function drawOrbitBehaviorPreference(_, _, customData)
  local orbitViewCenter = editor.getPreference(customData.path) == true
  if ui_imgui.RadioButton1(
    "Rotate in place##cameraV2OrbitBehavior",
    not orbitViewCenter) then
    editor.setPreference(customData.path, false)
  end
  if ui_imgui.RadioButton1(
    "Orbit view center##cameraV2OrbitBehavior",
    orbitViewCenter) then
    editor.setPreference(customData.path, true)
  end
end

local function drawWasdModePreference(_, _, customData)
  local current = editor.getPreference(customData.path) or "standard"
  if ui_imgui.RadioButton1(
    "WASD (standard)##cameraV2WasdStandard",
    current == "standard") then
    editor.setPreference(customData.path, "standard")
  end
  if ui_imgui.RadioButton1(
    "WASD (pan)##cameraV2WasdPan",
    current == "pan") then
    editor.setPreference(customData.path, "pan")
  end
end

local function preferenceDefinitions()
  return {
    {swapPanOrbitButtons = {
      "bool",
      true,
      "Choose which mouse buttons pan and orbit",
      "Mouse button layout",
      nil,
      nil,
      nil,
      nil,
      drawMouseLayoutPreference
    }},
    {orbitAroundViewCenter = {
      "bool",
      true,
      "Choose whether orbit rotates in place or around the view-center surface",
      "Orbit behavior",
      nil,
      nil,
      nil,
      nil,
      drawOrbitBehaviorPreference
    }},
    {wasdMode = {
      "string",
      "standard",
      "Choose whether WASD flies the camera in 3D or pans across the XY ground plane",
      "Keyboard Navigation",
      nil,
      nil,
      nil,
      nil,
      drawWasdModePreference
    }},
    {wasdPanSpeedMultiplier = {
      "float",
      0.5,
      "Normal WASD pan speed multiplier",
      "WASD pan speed",
      0.05,
      5
    }},
    {wasdPanFastSpeedMultiplier = {
      "float",
      1.5,
      "Shift-modified WASD pan speed multiplier",
      "WASD pan fast speed",
      0.05,
      10
    }},
    {showDebugWindow = {"bool", false, "Show the Camera V2 debug window"}},
    {zoomFactorPerNotch = {"float", 1.5, "Multiplicative distance change per wheel notch", nil, 1.01, 3}},
    {zoomMinDistance = {"float", 0.25, "Minimum distance from the active zoom focus", nil, 0.05, 1000}},
    {zoomMaxDistance = {"float", 2500, "Maximum distance from the active zoom focus", nil, 10, 2500}},
    {zoomResponse = {
      "float",
      20,
      "Controls how quickly mouse-driven camera movement catches up. Higher values feel more responsive; lower values feel smoother.",
      "Mouse motion responsiveness",
      1,
      40
    }},
    {inertiaDuration = {
      "float",
      0.35,
      "Time for released mouse movement to lose about 95% of its velocity",
      "Mouse inertia duration",
      0.05,
      2
    }}
  }
end

local function drawControllerPreference(_, _, customData)
  local current = editor.getPreference(customData.path) or "stock"
  if ui_imgui.RadioButton1("v1##activeEditorCamera", current == "stock") then
    editor.setPreference(customData.path, "stock")
  end
  ui_imgui.SameLine()
  if ui_imgui.RadioButton1("v2 (experimental)##activeEditorCamera", current == "cameraV2") then
    editor.setPreference(customData.path, "cameraV2")
  end
end

local function setEnabled(enabled)
  enabled = enabled == true
  if enabled == registered then
    if windowRegistered then
      if enabled and editor.getPreference(preferencePrefix .. "showDebugWindow") ~= false then
        editor.showWindow(debugWindowName)
      else
        editor.hideWindow(debugWindowName)
      end
    end
    return
  end
  if enabled then
    if registry.register(controllerId, controller, 0) then
      registered = true
      controller.activate()
      if windowRegistered
        and editor.getPreference(preferencePrefix .. "showDebugWindow") ~= false then
        editor.showWindow(debugWindowName)
      end
    else
      editor.logError("CameraV2 could not register its camera controller")
    end
  else
    registry.unregister(controllerId, controller)
    registered = false
    controller.deactivate()
    if windowRegistered then editor.hideWindow(debugWindowName) end
  end
end

local function isEffectiveEnabled()
  return editor
    and editor.active
    and ((editor.getPreference and editor.getPreference(controllerPreferencePath) == "cameraV2")
      or temporaryEnabled == true)
end

local function syncWasdMode()
  local effective = isEffectiveEnabled()
  local wasdPan = effective and (editor and editor.getPreference and editor.getPreference(preferencePrefix .. "wasdMode") == "pan")
  controller.setPlanarTranslation(wasdPan)
end

local function updateEnabledState()
  setEnabled(isEffectiveEnabled())
  syncWasdMode()
end

function M.setTemporaryEnabled(enabled)
  temporaryEnabled = enabled == true
  updateEnabledState()
end

local function formatDistance(label, point, cameraPosition)
  if not point then return label .. ": no hit" end
  return string.format("%s: %.2f m", label, (vec3(point) - cameraPosition):length())
end

local function selectedFocus()
  if not editor.selection
    or not editor.selection.object
    or #editor.selection.object == 0 then
    return nil
  end
  if editor.computeSelectionBBox then editor.computeSelectionBBox() end
  local box = editor.objectSelectionBBox
  local focus = box and box.getCenter and vec3(box:getCenter()) or nil
  return validation.isReasonablePoint(focus) and focus or nil
end

local function playerFocus()
  local vehicle = getPlayerVehicle(0)
  local focus = vehicle and vehicle.getPosition and vec3(vehicle:getPosition()) or nil
  return validation.isReasonablePoint(focus) and focus or nil
end

local function fallbackFocus()
  local focus = selectedFocus() or playerFocus() or vec3(0, 0, 0)
  local terrainHeight = validation.terrainHeightAt(focus)
  if terrainHeight then focus.z = terrainHeight end
  return focus
end

local function cameraPoseIsValid()
  return validation.isReasonablePoint(core_camera.getPosition())
    and validation.isValidQuaternion(core_camera.getQuat())
end

local function recoverCamera()
  local currentPosition = vec3(core_camera.getPosition())
  local currentRotation = core_camera.getQuat()
  local positionValid = validation.isReasonablePoint(currentPosition)
  local xyValid = validation.isReasonableXY(currentPosition)
  local rotationValid = validation.isValidQuaternion(currentRotation)
  if positionValid and rotationValid then return true end
  local safeOffset = math.max(
    editor.getPreference(preferencePrefix .. "zoomMinDistance") or 0.25,
    50)
  local recoveredPosition
  local focus

  if xyValid then
    if validation.isReasonableCoordinate(currentPosition.z) then
      recoveredPosition = vec3(currentPosition)
    else
      local terrainHeight = validation.terrainHeightAt(currentPosition)
      if not terrainHeight then terrainHeight = 0 end
      if not validation.isReasonableCoordinate(terrainHeight) then terrainHeight = 0 end
      recoveredPosition = vec3(
        currentPosition.x,
        currentPosition.y,
        terrainHeight + safeOffset)
    end
  else
    focus = fallbackFocus()
    recoveredPosition = focus + vec3(0, -safeOffset, safeOffset * 0.5)
    local terrainHeight = validation.terrainHeightAt(recoveredPosition)
    if terrainHeight and recoveredPosition.z < terrainHeight + safeOffset then
      recoveredPosition.z = terrainHeight + safeOffset
    end
  end
  if not validation.isReasonablePoint(recoveredPosition) then return false end

  controller.cancel()
  if core_camera.clearMotion then core_camera.clearMotion(0) end
  if not positionValid then core_camera.setPosition(0, recoveredPosition) end
  if not rotationValid or not xyValid then
    local rotation
    if xyValid then
      rotation = quat(0, 0, 0, 1)
    else
      focus = focus or fallbackFocus()
      local direction = focus - recoveredPosition
      rotation = direction:length() > 0.0001
        and quatFromDir(direction)
        or quat(0, 0, 0, 1)
    end
    if not validation.isValidQuaternion(rotation) then return false end
    core_camera.setRotation(0, rotation)
  end
  return cameraPoseIsValid()
end

local function drawDebugWindow()
  if not registered then return end
  local cameraPosition = vec3(core_camera.getPosition())
  local poseValid = cameraPoseIsValid()
  local terrainHeight = validation.terrainHeightAt(cameraPosition)
  local cursorHit = poseValid
    and cameraMouseRayCast(false, nil, cursorRayDistance)
    or nil
  local cursorPoint = cursorHit and (cursorHit.pos or cursorHit.pt) or nil
  local forward = core_camera.getQuat() * vec3(0, 1, 0)
  if forward:length() > 0.0001 then forward:normalize() end
  local centerHit = poseValid and forward:length() > 0.0001
    and Engine.castRay(
      cameraPosition,
      cameraPosition + forward * 1000000,
      true,
      true)
    or nil

  ui_imgui.PushStyleColor2(ui_imgui.Col_WindowBg, debugWindowBg)
  ui_imgui.PushStyleColor2(ui_imgui.Col_TitleBg, debugTitleBg)
  ui_imgui.PushStyleColor2(ui_imgui.Col_TitleBgActive, debugTitleActiveBg)
  ui_imgui.PushStyleColor2(ui_imgui.Col_TitleBgCollapsed, debugTitleBg)
  ui_imgui.PushStyleColor2(ui_imgui.Col_Border, debugBorder)
  if editor.beginWindow(debugWindowName, "Camera V2 Debug") then
    if not poseValid then
      ui_imgui.TextColored(
        ui_imgui.ImVec4(1, 0.2, 0.2, 1),
        "Invalid camera coordinates detected")
    end
    if ui_imgui.Button("Recover Camera##cameraV2Recover") then recoverCamera() end
    ui_imgui.Separator()
    ui_imgui.TextUnformatted(
      "Controller capture: " .. (registry.isOwner(controllerId) and "active" or "idle"))
    ui_imgui.TextUnformatted(string.format(
      "Mouse layout: %s",
      editor.getPreference(preferencePrefix .. "swapPanOrbitButtons")
        and "Right pan / Middle orbit"
        or "Middle pan / Right orbit"))
    ui_imgui.TextUnformatted(
      "Orbit: " .. (editor.getPreference(preferencePrefix .. "orbitAroundViewCenter")
        and "View center"
        or "Rotate in place"))
    local orbitState = controller.orbitDebugState()
    ui_imgui.TextUnformatted(orbitState
      and string.format(
        "Orbit pivot: %s  %.2f m  %s",
        orbitState.source or "unknown",
        orbitState.distance or 0,
        orbitState.moving and "moving" or "ready")
      or "Orbit pivot: not initialized")
    ui_imgui.TextUnformatted(
      "Last zoom terrain-only: "
      .. (controller.lastZoomUsedTerrainOnly() and "yes" or "no"))
    ui_imgui.Separator()
    ui_imgui.TextUnformatted(string.format("World Z: %.2f m", cameraPosition.z))
    ui_imgui.TextUnformatted(terrainHeight
      and string.format("Height above terrain: %.2f m", cameraPosition.z - terrainHeight)
      or "Height above terrain: no terrain")
    ui_imgui.TextUnformatted(formatDistance("Cursor ray", cursorPoint, cameraPosition))
    ui_imgui.TextUnformatted(formatDistance(
      "Center ray",
      centerHit and centerHit.pt or nil,
      cameraPosition))
    ui_imgui.TextUnformatted(string.format(
      "WASD pan: %.2fx normal  %.2fx Shift",
      editor.getPreference(preferencePrefix .. "wasdPanSpeedMultiplier") or 0.5,
      editor.getPreference(preferencePrefix .. "wasdPanFastSpeedMultiplier") or 1.5))
    ui_imgui.Separator()
    ui_imgui.TextUnformatted(string.format(
      "Zoom: %.2fx  range %.2f–%.0f m  response %.1f  inertia %.2f s",
      editor.getPreference(preferencePrefix .. "zoomFactorPerNotch") or 1.5,
      editor.getPreference(preferencePrefix .. "zoomMinDistance") or 0.25,
      editor.getPreference(preferencePrefix .. "zoomMaxDistance") or 2500,
      editor.getPreference(preferencePrefix .. "zoomResponse") or 20,
      editor.getPreference(preferencePrefix .. "inertiaDuration") or 0.35))
  end
  editor.endWindow()
  ui_imgui.PopStyleColor(5)
end

local function drawElevationReference()
  if not editor or not editor.active then return end
  local cameraPosition = vec3(core_camera.getPosition())
  if not validation.isReasonablePoint(cameraPosition) then return end
  if cameraPosition.z <= referenceElevationThreshold then return end
  local origin = vec3(0, 0, 0)
  local terrainHeight = validation.terrainHeightAt(origin)
  if terrainHeight then origin.z = terrainHeight end
  local maximumElevation = editor.getPreference(preferencePrefix .. "zoomMaxDistance") or 2500
  if maximumElevation <= origin.z then return end
  debugDrawer:drawCylinder(
    origin,
    vec3(0, 0, maximumElevation),
    clamp(maximumElevation * 0.004, 2, 10),
    ColorF(1, 0.05, 0.05, 0.9))
end

local function drawOrbitPivot()
  if editor.getPreference(preferencePrefix .. "showDebugWindow") == false then return end
  local orbitState = controller.orbitDebugState()
  if orbitState
    and validation.isReasonablePoint(orbitState.pivot)
    and validation.isFinite(orbitState.distance) then
    local radius = clamp(orbitState.distance * 0.01, 0.1, 10)
    debugDrawer:drawSphere(orbitState.pivot, radius, ColorF(1, 0, 0, 1), false)
  end
  local panState = controller.panDebugState()
  if panState
    and validation.isReasonablePoint(panState.point)
    and validation.isFinite(panState.distance) then
    local sphereRadius = clamp(panState.distance * 0.01, 0.1, 10)
    debugDrawer:drawCylinder(
      panState.point,
      panState.point + vec3(0, 0, sphereRadius * 10),
      sphereRadius * 0.5,
      ColorF(0.1, 0.55, 1, 1))
  end
end

function M.onEditorRegisterPreferences(prefsRegistry)
  prefsRegistry:registerCategory("camera", "Camera")
  local activeDefinition = {{
    activeCamera = {
      "string",
      "stock",
      "Choose the camera version used by the World Editor",
      "Camera Version",
      nil,
      nil,
      nil,
      nil,
      drawControllerPreference
    }
  }}
  local activeItem = prefsRegistry:findItem(controllerPreferencePath)
  if activeItem then
    activeItem.defaultValue = "stock"
    activeItem.description = "Choose the camera version used by the World Editor"
    activeItem.label = "Camera Version"
    activeItem.customUiFunc = drawControllerPreference
    activeItem.hidden = false
    activeDefinition = nil
  end
  prefsRegistry:registerSubCategory("camera", "general", "General", activeDefinition)

  local missingCameraV2 = {}
  for _, definition in ipairs(preferenceDefinitions()) do
    local name, info = next(definition)
    local item = prefsRegistry:findItem(preferencePrefix .. name)
    if item then
      item.defaultValue = info[2]
      item.description = info[3] or ""
      item.label = info[4] or string.sentenceCase(name)
      item.minValue = info[5]
      item.maxValue = info[6]
      item.customUiFunc = info[9]
      item.hidden = info[7] or false
    else
      missingCameraV2[#missingCameraV2 + 1] = definition
    end
  end
  prefsRegistry:registerSubCategory(
    "camera",
    "cameraV2",
    "Camera v2 (experimental)",
    #missingCameraV2 > 0 and missingCameraV2 or nil)

  local category = prefsRegistry:findCategory("camera")
  local general = category and prefsRegistry:findSubCategory(category, "general") or nil
  if general then
    for itemIndex, item in ipairs(general.items) do
      if item.name == "activeCamera" then
        table.remove(general.items, itemIndex)
        table.insert(general.items, 1, item)
        break
      end
    end
  end
  if category then
    local generalSubcategory = prefsRegistry:findSubCategory(category, "general")
    local cameraV2Subcategory = prefsRegistry:findSubCategory(category, "cameraV2")
    for index = #category.subcategories, 1, -1 do
      local subcategory = category.subcategories[index]
      if subcategory == generalSubcategory
        or subcategory == cameraV2Subcategory then
        table.remove(category.subcategories, index)
      end
    end
    if generalSubcategory then table.insert(category.subcategories, 1, generalSubcategory) end
    if cameraV2Subcategory then
      table.insert(category.subcategories, generalSubcategory and 2 or 1, cameraV2Subcategory)
    end
  end
end

function M.onEditorInitialized()
  editor.registerWindow(
    debugWindowName,
    ui_imgui.ImVec2(360 * ui_imgui.uiscale[0], 250 * ui_imgui.uiscale[0]))
  windowRegistered = true
  updateEnabledState()
end

function M.onEditorActivated()
  updateEnabledState()
end

function M.onEditorDeactivated()
  controller.setPlanarTranslation(false)
  setEnabled(false)
end

function M.onEditorPreferenceValueChanged(path, value)
  if path == controllerPreferencePath then
    updateEnabledState()
  elseif path == preferencePrefix .. "wasdMode" then
    syncWasdMode()
  elseif path == preferencePrefix .. "showDebugWindow" then
    if registered and value then
      editor.showWindow(debugWindowName)
    else
      editor.hideWindow(debugWindowName)
    end
  elseif string.startswith(path, preferencePrefix) and registered then
    controller.cancel()
  end
end

function M.onUpdate(dtReal)
  if registered then
    if not cameraPoseIsValid()
      and (not recoverCamera() or not cameraPoseIsValid()) then
      return
    end
    local deltaTime = dtReal or ui_imgui.GetIO().DeltaTime or 0
    controller.update(clamp(deltaTime, 0, 0.05))
    drawElevationReference()
    drawOrbitPivot()
  end
end

function M.consumeFocusDoubleClick()
  return registered and controller.consumeFocusDoubleClick() or false
end

function M.onEditorGui()
  if editor.getPreference(preferencePrefix .. "showDebugWindow") ~= false then
    drawDebugWindow()
  end
end

function M.onExtensionUnloaded()
  if controller and controller.setPlanarTranslation then
    controller.setPlanarTranslation(false)
  end
  setEnabled(false)
  if windowRegistered and editor.unregisterWindow then
    editor.unregisterWindow(debugWindowName)
  end
  windowRegistered = false
end

return M
