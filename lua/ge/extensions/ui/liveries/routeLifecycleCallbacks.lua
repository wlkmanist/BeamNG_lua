-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {"ui_liveries_saves", "ui_liveries", "ui_liveries_fill", "ui_liveries_decal", "ui_liveries_textures", "ui_liveries_camera"}

local LIVERIES_ROUTE = "liveries"
local LIVERIES_PAUSE_REQUEST_ID = "ui_liveries"
local DECALS_ROUTE = "liveries.edit.decals"
local EDIT_ROUTE = "liveries.edit"
local DECAL_TRANSFORM_ROUTE = "liveries.edit.decals.camera.selector.transform"
local EXISTING_DECAL_TRANSFORM_ROUTE = "liveries.edit.decals.transform"
local DECAL_TRANSFORM_SETTINGS_ROUTE = "liveries.edit.decals.camera.selector.transform.settings"
local EXISTING_DECAL_TRANSFORM_SETTINGS_ROUTE = "liveries.edit.decals.transform.settings"

local function isEditRouteName(routeName)
  if type(routeName) ~= "string" then return false end
  return routeName == EDIT_ROUTE or string.startswith(routeName, EDIT_ROUTE .. ".")
end

local function isDecalsRouteName(routeName)
  if type(routeName) ~= "string" then return false end
  return routeName == DECALS_ROUTE or string.startswith(routeName, DECALS_ROUTE .. ".")
end

local function isLiveriesRouteName(routeName)
  if type(routeName) ~= "string" then return false end
  return routeName == LIVERIES_ROUTE or string.startswith(routeName, LIVERIES_ROUTE .. ".")
end

-- leave hooks chain into each other, so the request state is tracked to keep push/pop balanced
local pauseRequestActive = false

-- the sim must stay paused inside liveries so vehicle triggers (doors, hood, trunk) cannot fire
local function syncLiveriesSimulationPause(fromRoute, toRoute)
  local wasInLiveries = isLiveriesRouteName(fromRoute and fromRoute.name)
  local nowInLiveries = isLiveriesRouteName(toRoute and toRoute.name)

  if nowInLiveries and not wasInLiveries then
    if not pauseRequestActive and simTimeAuthority and simTimeAuthority.pushPauseRequest then
      simTimeAuthority.pushPauseRequest(LIVERIES_PAUSE_REQUEST_ID)
      pauseRequestActive = true
    end
  elseif wasInLiveries and not nowInLiveries then
    if pauseRequestActive and simTimeAuthority and simTimeAuthority.popPauseRequest then
      simTimeAuthority.popPauseRequest(LIVERIES_PAUSE_REQUEST_ID)
      pauseRequestActive = false
    end
  end
end

local function isDecalTransformSettingsRoute(toRoute)
  return type(toRoute) == "table" and toRoute.name == DECAL_TRANSFORM_SETTINGS_ROUTE
end

local function isExistingDecalTransformSettingsRoute(toRoute)
  return type(toRoute) == "table" and toRoute.name == EXISTING_DECAL_TRANSFORM_SETTINGS_ROUTE
end

local function isAnyDecalTransformSettingsRoute(route)
  return isDecalTransformSettingsRoute(route) or isExistingDecalTransformSettingsRoute(route)
end

local function isDecalTransformRoute(route)
  if type(route) ~= "table" or type(route.name) ~= "string" then return false end
  return route.name == DECAL_TRANSFORM_ROUTE or route.name == EXISTING_DECAL_TRANSFORM_ROUTE
end

local function onLiveriesEnter(context, toRoute, fromRoute, data)
  syncLiveriesSimulationPause(fromRoute, toRoute)

  data.liveries = {
    saveFiles = ui_liveries_saves.getAll(),
  }
end

local function onLiveriesMount(context, toRoute, fromRoute, data)
end

local function onLiveriesEditEnter(context, toRoute, fromRoute, data)
  syncLiveriesSimulationPause(fromRoute, toRoute)

  -- moving around inside edit (paint, decals, etc.) keeps the same session alive
  if not isEditRouteName(fromRoute and fromRoute.name) then
    local params = type(toRoute) == "table" and toRoute.params or nil
    -- no save name means the player asked for a brand new livery
    local saveName = type(params) == "table" and params.saveName or nil

    if not ui_liveries.setup(saveName) then
      log("W", "liveries", "livery editor session started without its layer stack, saveName: " .. dumps(saveName))
    end
  end

  -- the save form needs the session's identity to offer overwriting instead of a duplicate name
  data.liveries = data.liveries or {}
  data.liveries.currentSaveName = ui_liveries_saves.getCurrentSaveName()
end

local function onLiveriesPaintEnter(context, toRoute, fromRoute, data)
  data.liveries = data.liveries or {}
  data.liveries.layerPaint = ui_liveries_fill.getPaint()
end

-- the home screen has no other leave hook, so the root pop happens here
local function onLiveriesRootLeave(context, toRoute, fromRoute, data)
  syncLiveriesSimulationPause(fromRoute, toRoute)
end

local function onLiveriesLeave(context, toRoute, fromRoute, data)
  syncLiveriesSimulationPause(fromRoute, toRoute)

  -- staying inside the edit branch (paint, decals, etc.) keeps the session alive
  if isEditRouteName(toRoute and toRoute.name) then return end

  ui_liveries.teardown()

  local stagedSkinName = ui_liveries_saves.consumeStagedApplySkin()
  if stagedSkinName then
    core_vehicle_partmgmt.setSkin(stagedSkinName)
  end
end

local function onDecalsEnter(context, toRoute, fromRoute, data)
  syncLiveriesSimulationPause(fromRoute, toRoute)

  -- moving around inside the decals branch keeps the layer stack and selection alive
  if isDecalsRouteName(fromRoute and fromRoute.name) then return end

  ui_liveries_decal.setup()
end

local function onDecalsMount(context, toRoute, fromRoute, data)
  ui_liveries_decal.notifyUi()
end

local function onDecalCameraEnter(context, toRoute, fromRoute, data)
  onDecalsEnter(context, toRoute, fromRoute, data)

  data.liveries = data.liveries or {}
  data.liveries.cameraViews = ui_liveries_camera.getViews()
end

local function onDecalMaterialEnter(context, toRoute, fromRoute, data)
  onDecalsEnter(context, toRoute, fromRoute, data)

  local params = type(toRoute) == "table" and toRoute.params or nil
  local layerUid = type(params) == "table" and params.layerUid or nil
  ui_liveries_camera.panToLayer(layerUid)

  data.liveries = data.liveries or {}
  data.liveries.layerPaint = ui_liveries_decal.getPaint(layerUid)
end

local function onDecalMirrorEnter(context, toRoute, fromRoute, data)
  onDecalsEnter(context, toRoute, fromRoute, data)

  local params = type(toRoute) == "table" and toRoute.params or nil
  local layerUid = type(params) == "table" and params.layerUid or nil
  if not layerUid then
    log("W", "liveries", "decal mirror route entered without a layerUid param")
  end

  ui_liveries_camera.orbitToLayer(layerUid)

  data.liveries = data.liveries or {}
  data.liveries.decalMirror = ui_liveries_decal.getLayerMirror(layerUid)
end

local function onDecalSelectorMount(context, toRoute, fromRoute, data)
  ui_liveries_textures.loadTextures()
end

local function onDecalTransformMount(context, toRoute, fromRoute, data)
  ui_liveries_decal.notifyUi()
  if isAnyDecalTransformSettingsRoute(fromRoute) then
    ui_liveries_decal.resumeTransformActionMap()
  else
    ui_liveries_decal.showSelectedCursor()
  end

  data.liveries = data.liveries or {}
  data.liveries.decalTransform = ui_liveries_decal.getTransformSnapshot()
  data.liveries.decalMouseMode = { useMousePos = ui_liveries_decal.isUseMousePos() }
end

local function onDecalsLeave(context, toRoute, fromRoute, data)
  syncLiveriesSimulationPause(fromRoute, toRoute)

  if isDecalsRouteName(toRoute and toRoute.name) then return end

  ui_liveries_decal.teardown()
  onLiveriesLeave(context, toRoute, fromRoute, data)
end

local function onDecalTransformLeave(context, toRoute, fromRoute, data)
  if not isDecalTransformSettingsRoute(toRoute) then
    ui_liveries_decal.hideSelectedCursor()
  end
  onDecalsLeave(context, toRoute, fromRoute, data)
end

local function onDecalTransformSettingsEnter(context, toRoute, fromRoute, data)
  onDecalsEnter(context, toRoute, fromRoute, data)
  ui_liveries_decal.suspendTransformActionMap()

  data.liveries = data.liveries or {}
  data.liveries.decalMirror = ui_liveries_decal.getMirrorSnapshot()
  data.liveries.layerPaint = ui_liveries_decal.getTransformPaint()
end

local function onDecalTransformSettingsLeave(context, toRoute, fromRoute, data)
  if isDecalTransformRoute(toRoute) then
    ui_liveries_decal.resumeTransformActionMap()
    return
  end
  onDecalsLeave(context, toRoute, fromRoute, data)
end

local function onExistingDecalTransformEnter(context, toRoute, fromRoute, data)
  onDecalsEnter(context, toRoute, fromRoute, data)

  local params = type(toRoute) == "table" and toRoute.params or nil
  local layerUid = type(params) == "table" and params.layerUid or nil
  if not layerUid then
    log("W", "liveries", "existing decal transform route entered without a layerUid param")
    return
  end

  ui_liveries_decal.beginExistingTransform(layerUid)
end

local function onExistingDecalTransformMount(context, toRoute, fromRoute, data)
  if isAnyDecalTransformSettingsRoute(fromRoute) then
    ui_liveries_decal.resumeTransformActionMap()
  else
    ui_liveries_decal.showExistingCursor()
  end

  data.liveries = data.liveries or {}
  data.liveries.decalTransform = ui_liveries_decal.getTransformSnapshot()
  data.liveries.decalMouseMode = { useMousePos = ui_liveries_decal.isUseMousePos() }
end

local function onExistingDecalTransformLeave(context, toRoute, fromRoute, data)
  if not isExistingDecalTransformSettingsRoute(toRoute) then
    ui_liveries_decal.endExistingTransform()
  end
  onDecalsLeave(context, toRoute, fromRoute, data)
end

M.onLiveriesEnter = onLiveriesEnter
M.onLiveriesMount = onLiveriesMount
M.onLiveriesEditEnter = onLiveriesEditEnter
M.onLiveriesRootLeave = onLiveriesRootLeave
M.onLiveriesLeave = onLiveriesLeave
M.onLiveriesPaintEnter = onLiveriesPaintEnter
M.onDecalsEnter = onDecalsEnter
M.onDecalsMount = onDecalsMount
M.onDecalCameraEnter = onDecalCameraEnter
M.onDecalMaterialEnter = onDecalMaterialEnter
M.onDecalMirrorEnter = onDecalMirrorEnter
M.onDecalSelectorMount = onDecalSelectorMount
M.onDecalTransformMount = onDecalTransformMount
M.onDecalsLeave = onDecalsLeave
M.onDecalTransformLeave = onDecalTransformLeave
M.onDecalTransformSettingsEnter = onDecalTransformSettingsEnter
M.onDecalTransformSettingsLeave = onDecalTransformSettingsLeave
M.onExistingDecalTransformEnter = onExistingDecalTransformEnter
M.onExistingDecalTransformMount = onExistingDecalTransformMount
M.onExistingDecalTransformLeave = onExistingDecalTransformLeave

return M