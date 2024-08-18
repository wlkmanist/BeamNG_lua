-- Should include implementation for action maps,
-- disable other action maps.
-- for example, disabling camera action controls when applying a decal
local M = {}

-- M.dependencies = {
--   "editor_api_dynamicDecals"
-- }

local api = extensions.editor_api_dynamicDecals

local ACTION_MAPS = {
  transform = "LiveryEditorTransform",
  transformStamp = "LiveryEditorTransformStamp",
  deform = "LiveryEditorDeform",
  material = "LiveryEditorMaterial"
}

local disableAllActionMaps = function()
  for key, value in pairs(ACTION_MAPS) do
    popActionMap(value)
  end
end

local toggleActionMap = function(actionMap, enable)
  local o = scenetree.findObject(actionMap.."ActionMap")
  if o then
    o:setEnabled(enable)
  end
end

M.useMouseProjection = function()
  local isUseMousePos = api.isUseMousePos()

  if isUseMousePos then
    return
  end

  -- disable unapplicable action maps
  -- M.useActionMap(ACTION_MAPS.transformStamp)
  pushActionMap(ACTION_MAPS.transformStamp)
  toggleActionMap(ACTION_MAPS.transform, false)

  api.toggleSetting(api.settingsFlags.UseMousePos.value)
end

M.useCursorProjection = function()
  local isUseMousePos = api.isUseMousePos()

  if not isUseMousePos then
    return
  end

  popActionMap(ACTION_MAPS.transformStamp)
  toggleActionMap(ACTION_MAPS.transform, true)
  api.toggleSetting(api.settingsFlags.UseMousePos.value)
end

M.useActionMap = function(actionMapKey)
  log("D", "", "useActionMap " .. actionMapKey)
  disableAllActionMaps()
  local actionMap = ACTION_MAPS[actionMapKey]
  if actionMap then
    log("D", "", "pushing actionMap " .. actionMap)
    pushActionMap(actionMap)
  end
end

M.disableActionMap = function(actionMap)
  popActionMap(actionMap)
end

-- M.editAsController = function()
--   api.toggleSetting(api.settingsFlags.UseMousePos.value)
-- end

-- M.toggleUseMousePos = function()
--   api.toggleSetting(api.settingsFlags.UseMousePos.value)
--   api.setDecalColor(Point4F(1, 1, 1, 1))
--   dump("toggleUseMousePos", api.settingsFlags.UseMousePos)
--   dump("settings", api.isUseMousePos())
-- end


-- TODO: Refactor this to toggle action map based on mode (normal/edit) and selected decal(should probably be called from selected lua module)
M.toggleEditActionMaps = function(enable)
  local o = scenetree.findObject("liveryEditorActionMap")
  if o then
    o:setEnabled(enable)
  end
end

-- TODO: Remove/Rename this and move all unrelated action maps to livery editor here
M.enableVehicleControls = function(enable)
  local commonActionMap = scenetree.findObject("VehicleCommonActionMap")
  if commonActionMap then
    commonActionMap:setEnabled(enable)
  end

  local specificActionMap = scenetree.findObject("VehicleSpecificActionMap")
  if specificActionMap then
    specificActionMap:setEnabled(enable)
  end
end

M.disableAllActionMaps = disableAllActionMaps
M.ACTION_MAPS = ACTION_MAPS

return M
