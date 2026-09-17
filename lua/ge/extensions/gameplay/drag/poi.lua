-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "drag_poi"

M.dependencies = {'gameplay_drag_rulesMenu'}

local function getStagePosition(lane)
  if not lane or not lane.waypoints or not lane.waypoints.stage then return nil end
  local t = lane.waypoints.stage.transform
  if not t or not t.position then return nil end
  if career_career and career_modules_tutorial and career_modules_tutorial.isActive() then
    return vec3(t.position) + t.rot * vec3(0,-10, 0)
  end
  return vec3(t.position)
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
        pos = pos,
        radius = 6,
        onInside = function()
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
          -- Work on a local copy so the cached level data is never mutated by user rules.
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
