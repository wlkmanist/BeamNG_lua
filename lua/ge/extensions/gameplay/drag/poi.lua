-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "drag_poi"

M.dependencies = {'gameplay_drag_rulesMenu'}

local JOIN_RADIUS_SQ = 6 * 6
local handleMultiseatEntry
local rejoinBlockedVehIds = {}

local function isMultiseatActive()
  return core_multiseat
    and core_multiseat.isMultiseatActive
    and core_multiseat.isMultiseatActive()
    or false
end

local function getStagePosition(lane)
  if not lane or not lane.waypoints or not lane.waypoints.stage then return nil end
  local t = lane.waypoints.stage.transform
  if not t or not t.position then return nil end
  if career_career and career_modules_tutorial and career_modules_tutorial.isActive() then
    return vec3(t.position) + t.rot * vec3(0,-10, 0)
  end
  return vec3(t.position)
end

local function isNearAnyStage(lanes, vehPos)
  for _, lane in ipairs(lanes or {}) do
    local t = lane.waypoints and lane.waypoints.stage and lane.waypoints.stage.transform
    if t and t.position and vehPos:squaredDistance(t.position) <= JOIN_RADIUS_SQ then return true end
  end
  return false
end

-- racers still at the stage line won't rejoin a new drag until they drive out of all stage triggers
function M.blockRejoinForStagedRacers()
  local data = gameplay_drag_core.getData()
  if not data or not data.racers or not data.strip then return end
  for vehId in pairs(data.racers) do
    local veh = scenetree.findObjectById(vehId)
    if veh and isNearAnyStage(data.strip.lanes, veh:getPosition()) then
      rejoinBlockedVehIds[vehId] = true
    end
  end
end

function M.clearRejoinBlocks()
  table.clear(rejoinBlockedVehIds)
end

function M.applyUserRulesToData(data, stripId, levelId)
  if not stripId or not levelId then return end
  local userRules = gameplay_drag_rulesMenu.getSavedRulesForStrip(levelId, stripId)
  if not userRules then return end
  if userRules.dragType then data.dragType = userRules.dragType end
  if userRules.importantTimerId then data.importantTimerId = userRules.importantTimerId end
  if userRules.treeType then
    if not data.prefabs then data.prefabs = {} end
    if not data.prefabs.christmasTree then data.prefabs.christmasTree = {} end
    data.prefabs.christmasTree.treeType = userRules.treeType
  end
end

function M.createStagePoi(data, lane, laneIndex)
  local core = gameplay_drag_core
  local pos = getStagePosition(lane)
  if not pos then
    log('W', logTag, string.format('No stage position found for lane %d in strip %s', laneIndex, data._fnWithoutExt or 'unknown'))
    return nil
  end
  local stripName = data._fnWithoutExt or "unknown"
  local laneName = lane.shortName or ("lane" .. laneIndex)
  return {
    id = string.format("drag##%s-%s", stripName, laneName),
    markerInfo = {
      invisibleTrigger = {
        multiseat = true,
        pos = pos,
        radius = 6,
        onExit = function(interactData)
          if interactData.veh and not isNearAnyStage(data.strip.lanes, interactData.vehPos) then
            rejoinBlockedVehIds[interactData.veh:getID()] = nil
          end
        end,
        onInside = function(interactData)
          if interactData.veh and rejoinBlockedVehIds[interactData.veh:getID()] then return end
          if isMultiseatActive() then
            handleMultiseatEntry(data, laneIndex, pos, interactData)
            return
          end

          local poiKey = string.format("%s-%d", stripName, laneIndex)
          if core.getGameplayContext() == "freeroam" and not (core.getDragGamemode() and core.getDragGamemode().isMultiplayer and core.getDragGamemode().isMultiplayer()) and gameplay_drag_dragBridge then
            local currentData = core.getData()
            local raceFinished = currentData and (currentData.isCompleted or core.allRacersFinished(currentData))
            if core.getDragIsStarted() and raceFinished then
              core.setPoiJoinRequestSent(poiKey, false)
              gameplay_drag_dragBridge.reset()
            end
          end
          if core.getDragIsStarted() then return end
          if core.isPoiJoinRequestSent(poiKey) then return end

          local vehicleId = be:getPlayerVehicleID(0)
          if not vehicleId or vehicleId == -1 then return end

          local drag = core.getDragGamemode()
          if drag and drag.shouldSyncState and drag.shouldSyncState() then
            if drag then
              if drag.setContext then drag.setContext(deepcopy(data), laneIndex) end
              if drag.isMenuOpen and not drag.isMenuOpen() and drag.openMenu then drag.openMenu(deepcopy(data), laneIndex) end
            end
            return
          end

          local stripId = data.id or data._fnWithoutExt
          local levelId = getCurrentLevelIdentifier()
          local localData = deepcopy(data)
          M.applyUserRulesToData(localData, stripId, levelId)

          local treeType = localData.prefabs and localData.prefabs.christmasTree and localData.prefabs.christmasTree.treeType or ".500"
          if localData.prefabs and localData.prefabs.christmasTree then
            localData.prefabs.christmasTree.treeType = treeType
          end
          core.setDragRaceData(deepcopy(localData))
          if core.startDragRaceActivity(laneIndex) then
            core.setPoiJoinRequestSent(poiKey, true)
          end
        end,
      },
    },
  }
end

local function isLaneOccupied(activeData, laneIndex, excludeVehId)
  if not activeData or not activeData.racers then return false end
  for vehId, racer in pairs(activeData.racers) do
    if vehId ~= excludeVehId and racer.lane == laneIndex and not racer.vehicleRemoved then
      return true
    end
  end
  return false
end

local function isClosestLane(lanes, laneIndex, vehPos, pos)
  local ownDistSq = vehPos:squaredDistance(pos)
  for i, lane in ipairs(lanes) do
    local t = i ~= laneIndex and lane.waypoints and lane.waypoints.stage and lane.waypoints.stage.transform
    if t and t.position and vehPos:squaredDistance(t.position) < ownDistSq then return false end
  end
  return true
end

local function startFreshMultiseatActivity(core, data, laneIndex, vehicleId)
  local stripId = data.id or data._fnWithoutExt
  local levelId = getCurrentLevelIdentifier()
  local localData = deepcopy(data)
  M.applyUserRulesToData(localData, stripId, levelId)

  local treeType = localData.prefabs and localData.prefabs.christmasTree and localData.prefabs.christmasTree.treeType or ".500"
  if localData.prefabs and localData.prefabs.christmasTree then
    localData.prefabs.christmasTree.treeType = treeType
  end
  core.setDragRaceData(deepcopy(localData))
  core.startDragRaceActivity(laneIndex, vehicleId)
end

handleMultiseatEntry = function(data, laneIndex, pos, interactData)
  local core = gameplay_drag_core
  if not core or not core.isDragEnabled or not core.isDragEnabled() then return end
  if core.getGameplayContext() ~= "freeroam" then return end
  if core.getDragGamemode and core.getDragGamemode() then return end -- online MP owns its own join flow
  if not data.strip or not data.strip.lanes or not data.strip.lanes[laneIndex] then return end
  if not pos or not interactData or interactData.playerIndex == nil or interactData.isWalking then return end
  if not interactData.veh or not interactData.vehPos then return end
  if interactData.vehPos:squaredDistance(pos) > JOIN_RADIUS_SQ then return end
  if not isClosestLane(data.strip.lanes, laneIndex, interactData.vehPos, pos) then return end

  local vehicleId = interactData.veh:getID()
  if not vehicleId or vehicleId == -1 then return end

  local activeData = core.getData()
  local isSameStrip = activeData and core.getPoiKey(activeData) == core.getPoiKey(data)
  if activeData and not isSameStrip then return end

  if isSameStrip and core.getDragIsStarted() and (activeData.isCompleted or core.allRacersFinished(activeData)) then
    gameplay_drag_dragBridge.reset()
    activeData = core.getData()
  end

  if activeData and not core.isJoinWindowOpen(activeData) then return end
  if activeData and activeData.racers and activeData.racers[vehicleId] then return end

  if not activeData then
    startFreshMultiseatActivity(core, data, laneIndex, vehicleId)
  elseif not isLaneOccupied(activeData, laneIndex, vehicleId) then
    core.startDragRaceActivity(laneIndex, vehicleId)
  end
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  local core = gameplay_drag_core
  if not core or not core.isDragEnabled or not core.isDragEnabled() then return end
  local dragDataList = core.getDragDataForLevel and core.getDragDataForLevel(levelIdentifier)
  if not dragDataList then return end
  for _, data in pairs(dragDataList) do
    if not data.strip or not data.strip.lanes then goto continue end
    for i, lane in ipairs(data.strip.lanes) do
      local poi = M.createStagePoi(data, lane, i)
      if poi then table.insert(elements, poi) end
    end
    ::continue::
  end
end

return M
