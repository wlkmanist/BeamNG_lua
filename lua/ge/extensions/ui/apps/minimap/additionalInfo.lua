local M = {}
local hasNewAdditionalInfo = false
local additionalInfo = {}

M.requestAdditionalInfo = function()
  hasNewAdditionalInfo = true
end

local oldDistToTarget = nil
local function resetDistToTarget()
  additionalInfo.distToTarget = nil
  hasNewAdditionalInfo = true
  oldDistToTarget = nil
end

local function checkRoute()
  local rp = core_groundMarkers.routePlanner
  if not rp or not rp.path or not rp.path[1] then
    if oldDistToTarget then
      resetDistToTarget()
    end
    return
  end
  local distToTarget, unit, _, _ = translateDistance(rp.path[1].distToTarget, "auto")
  if distToTarget ~= oldDistToTarget then
    oldDistToTarget = distToTarget
    additionalInfo.distToTarget = string.format("%.1f %s", distToTarget, unit)
    hasNewAdditionalInfo = true
  end
end


local function onReachedTargetPos()
  resetDistToTarget()
end

local lastLocationName = nil
local camPos = vec3()
local function checkLocationName()
  if not gameplay_city then return end
  camPos:set(core_camera.getPositionXYZ())
  local location = gameplay_city.getHighestPrioZone(camPos)
  local locationName = nil
  if location then
    locationName = _tr(location.name)
  else
    for _, lvl in ipairs(core_levels.getList()) do
      if string.lower(lvl.levelName) == getCurrentLevelIdentifier() then
        locationName = _tr(lvl.title)
      end
    end
  end

  if locationName ~= lastLocationName then
    additionalInfo.locationName = locationName
    lastLocationName = locationName
    hasNewAdditionalInfo = true
  end
end

local lastPoliceMode = "disabled"
local function checkPolice()
  local pursuitData = gameplay_police.getPursuitData()
  local policeMode = "disabled"
  if pursuitData and pursuitData.mode and pursuitData.mode > 0 then
    local policeVisible = pursuitData.policeVisible
    if policeVisible then
      policeMode = "visibleToPolice"
    else
      policeMode = "hiddenFromPolice"
    end
  end
  if policeMode ~= lastPoliceMode then
    additionalInfo.policeMode = policeMode
    lastPoliceMode = policeMode
    hasNewAdditionalInfo = true
  end
end

local function onUpdate()
  checkRoute()
  checkLocationName()
  checkPolice()

  if hasNewAdditionalInfo then
    hasNewAdditionalInfo = false
    guihooks.queueStream("minimap", additionalInfo)
  end
end

local function onClientEndMission()
  table.clear(additionalInfo)
  hasNewAdditionalInfo = true
end

local function onSetBigmapNavFocus(pos)
  if not pos then
    resetDistToTarget()
  end
end

M.onUpdate = onUpdate
M.onReachedTargetPos = onReachedTargetPos
M.onClientEndMission = onClientEndMission
M.onSetBigmapNavFocus = onSetBigmapNavFocus

return M