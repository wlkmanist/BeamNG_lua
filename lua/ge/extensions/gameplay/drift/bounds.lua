-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local im = ui_imgui

local red = {1,0,0}
local white = {1,1,1}

local isBeingDebugged
local gc = 0
local profiler = LuaProfiler("Drift bounds profiler")
local driftDebugInfo = {
  default = false,
  canBeChanged = true
}


local drawBounds

local sites
local boundsState = {} -- vehId -> { isOutOfBounds = bool }

local function setBounds(filePath, drawBounds_)
  if drawBounds_ == nil then drawBounds = true end

  sites = gameplay_sites_sitesManager.loadSites(filePath, true, true)
  sites:finalizeSites()
  table.clear(boundsState)
end

local function detectOutOfBounds()
  if not sites then return end

  local tracked = gameplay_drift_drift.getTrackedVehicles()
  if not tracked then return end

  -- mark vehicles that are no longer tracked
  for vehId, _ in pairs(boundsState) do
    if not tracked[vehId] then
      boundsState[vehId] = nil
    end
  end

  for vehId, _ in pairs(tracked) do
    local vehPos = gameplay_drift_drift.getVehPos(vehId)
    if vehPos then
      if not boundsState[vehId] then
        boundsState[vehId] = { isOutOfBounds = false }
      end
      local zones = sites:getZonesForPosition(vehPos)
      boundsState[vehId].isOutOfBounds = #zones == 0
    end
  end
end

local function drawZones()
  if not sites or not drawBounds then return end

  -- flash red if any vehicle is out of bounds
  local anyOutOfBounds = false
  for _, state in pairs(boundsState) do
    if state.isOutOfBounds then
      anyOutOfBounds = true
      break
    end
  end

  red[2] = math.abs(math.sin(Engine.Platform.getRuntime()*2))
  red[3] = red[2]

  for _, zone in pairs(sites.zones.objects) do
    zone:drawDebug(nil, anyOutOfBounds and red or white, 2, -0.5, not anyOutOfBounds)
  end
end

local function imguiDebug()
  if isBeingDebugged then
    if im.Begin("Drift bounds") then
      for vehId, state in pairs(boundsState) do
        im.Text("Veh " .. tostring(vehId) .. " out of bounds : " .. tostring(state.isOutOfBounds))
      end
    end
    im.End()
  end
end

local function onUpdate()
  isBeingDebugged = gameplay_drift_general.getExtensionDebug("gameplay_drift_bounds")
  imguiDebug()
  if gameplay_drift_general.getGeneralDebug() then profiler:start() end

  detectOutOfBounds()
  --drawZones()

  if gameplay_drift_general.getGeneralDebug() then
    profiler:add("Drift bounds")
    gc = profiler.sections[1].garbage
    profiler:finish(false)
  end
end

local function getIsOutOfBounds(vehId)
  if vehId then
    local state = boundsState[vehId]
    return state and state.isOutOfBounds or false
  end
  -- backward compat: true if ANY tracked vehicle is out of bounds
  for _, state in pairs(boundsState) do
    if state.isOutOfBounds then return true end
  end
  return false
end

local function getDriftDebugInfo()
  return driftDebugInfo
end

local function getGC()
  return gc
end

M.onUpdate = onUpdate

M.setBounds = setBounds

M.getIsOutOfBounds = getIsOutOfBounds
M.getDriftDebugInfo = getDriftDebugInfo
M.getGC = getGC

return M
