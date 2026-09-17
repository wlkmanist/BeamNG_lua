-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'ui_imgui'}

local whiteF = ColorF(1, 1, 1, 1)
local blackI = ColorI(0, 0, 0, 255)

local tempPos = vec3()
local tempVec = vec3()

local debugEnabled = false

local function toggleDebugEnabled()
  debugEnabled = not debugEnabled
  guihooks.trigger('vehicleDebugInfoEnabledChanged', debugEnabled)
end

local function getDebugEnabled()
  return debugEnabled
end

local function setDebugEnabled(value)
  debugEnabled = value
  guihooks.trigger('vehicleDebugInfoEnabledChanged', debugEnabled)
end

local function bdebugRequestViewportSize(vehId)
  local veh = getObjectByID(vehId)
  if not veh then return end

  local mainViewport = ui_imgui.GetMainViewport()
  veh:queueLuaCommand(stringFormatWorkBuffer("bdebug.receiveViewportSize(%d,%d)", mainViewport.Size.x, mainViewport.Size.y))
end

local function onUpdate(dt)
  if not debugEnabled then return end

  for vid, veh in activeVehiclesIterator() do
    tempPos:set(veh:getPositionXYZ())
    local rot = veh:getRefNodeRotation()
    local oobb = veh:getSpawnWorldOOBB()
    local textPos = oobb:getCenter()
    local halfExtents = oobb:getHalfExtents()
    tempVec:set(0, 0, halfExtents.z + 0.25)
    textPos:setAdd(tempVec)

    local text = string.format("Vehicle ID: %d", vid)
    debugDrawer:drawTextAdvanced(textPos, text, whiteF, true, false, blackI, false, true)

    text = string.format("Position: (%.2f, %.2f, %.2f)", tempPos.x, tempPos.y, tempPos.z)
    debugDrawer:drawTextAdvanced(textPos, text, whiteF, true, false, blackI, false, true)

    text = string.format("Rotation: (%.3f, %.3f, %.3f, %.3f)", rot.x, rot.y, rot.z, rot.w)
    debugDrawer:drawTextAdvanced(textPos, text, whiteF, true, false, blackI, false, true)
  end
end

local function onExtensionLoaded(serializedData)
  if serializedData then
    debugEnabled = serializedData.debugEnabled
  end
end

local function onSerialize()
  return {
    debugEnabled = debugEnabled
  }
end

M.toggleDebugEnabled = toggleDebugEnabled
M.getDebugEnabled = getDebugEnabled
M.setDebugEnabled = setDebugEnabled
M.bdebugRequestViewportSize = bdebugRequestViewportSize

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onSerialize = onSerialize

return M