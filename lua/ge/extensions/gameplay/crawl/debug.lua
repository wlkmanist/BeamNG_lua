-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = "crawl_debug"
M.dependencies = { 'ui_imgui' }

local debugWindowOpen = false
local debugData = {}
-- Dev-only: off by default so the debug window never pops up for players.
-- Enable at runtime via gameplay_crawl_debug.setEnableDebugWindow(true) or the editor's View menu.
local enableDebugWindow = false

local im = ui_imgui

local function formatTime(seconds)
  if not seconds then return "N/A" end
  local minutes = math.floor(seconds / 60)
  local secs = seconds % 60
  return string.format("%02d:%06.3f", minutes, secs)
end

local function getBoundaryStatus(crawlerData, trail)
  if not trail or not crawlerData then return "No trail" end

  local boundary = gameplay_crawl_general and gameplay_crawl_general.activeTrail and gameplay_crawl_general.activeTrail.boundary
  if not boundary then return "No boundary" end

  local vehiclePos = crawlerData.dynamicData.vehPos
  if not vehiclePos then return "No vehicle position" end

  if boundary.containsPoint2D then
    local inside = boundary:containsPoint2D(vehiclePos)
    return inside and "Inside" or "Outside"
  end

  return "Invalid boundary"
end

local function drawPenaltySystem()
  if not debugData.crawlerData then return end

  im.TextColored(im.ImVec4(1, 0.5, 0, 1), "=== PENALTY SYSTEM ===")
  im.Text("Penalty Points: " .. (debugData.crawlerData.points or 0))

  if debugData.crawlerData.points >= 50 then
    im.TextColored(im.ImVec4(1, 0, 0, 1), "DNF THRESHOLD REACHED!")
  end

  if debugData.isDisqualified then
    im.TextColored(im.ImVec4(1, 0, 0, 1), "DISQUALIFIED")
  end

  im.Separator()
end

local function drawInfractionData()
  if not debugData.crawlerData or not debugData.crawlerData.infractionData then return end

  local infData = debugData.crawlerData.infractionData

  im.TextColored(im.ImVec4(0.5, 0.5, 1, 1), "=== INFRACTION DATA ===")
  im.Text("Driving Backwards Cooldown: " .. string.format("%.1f", infData.drivingBackwardsCooldown or 0))
  im.Text("Boundary Violation Cooldown: " .. string.format("%.1f", infData.boundaryViolationCooldown or 0))
  im.Text("Recovery Cooldown: " .. string.format("%.1f", infData.recoveryCooldown or 0))
  im.Text("Recently Recovered: " .. (infData.recentlyRecovered and "Yes" or "No"))
  im.Separator()
end

local function drawRecoveryCheckpoint()
  if not debugData.lastRecoveryCheckpoint then return end

  im.TextColored(im.ImVec4(0, 1, 0.5, 1), "=== RECOVERY CHECKPOINT ===")
  local rcp = debugData.lastRecoveryCheckpoint
  im.Text("Index: " .. (rcp.index or "N/A"))
  im.Text("Position: " .. string.format("%.1f, %.1f, %.1f", rcp.position.x, rcp.position.y, rcp.position.z))
  im.Text("Time: " .. formatTime(rcp.time))
  im.Separator()
end

local function drawBoundaryExitPoints()
  if not debugData.crawlerId then return end

  local exitPoints = gameplay_crawl_boundary and gameplay_crawl_boundary.getCrawlerExitPoint and gameplay_crawl_boundary.getCrawlerExitPoint(debugData.crawlerId)
  if not exitPoints then return end

  im.TextColored(im.ImVec4(1, 0.8, 0, 1), "=== BOUNDARY EXIT POINT ===")
  im.Text("Exit Point: " .. string.format("%.1f, %.1f, %.1f", exitPoints.x, exitPoints.y, exitPoints.z))

  local vehiclePos = debugData.crawlerData and debugData.crawlerData.dynamicData and debugData.crawlerData.dynamicData.vehPos
  if vehiclePos then
    local distance = vehiclePos:distance(exitPoints)
    im.Text("Distance from Exit: " .. string.format("%.1f m", distance))

    if distance >= 10.0 then
      im.TextColored(im.ImVec4(1, 0, 0, 1), "DNF DISTANCE REACHED!")
    end
  end
  im.Separator()
end

local function drawEventLog()
  if not debugData.eventLog or #debugData.eventLog == 0 then return end

  im.TextColored(im.ImVec4(1, 0, 1, 1), "=== EVENT LOG ===")
  if im.CollapsingHeader1("Recent Events", im.TreeNodeFlags_DefaultOpen) then
    local startIdx = math.max(1, #debugData.eventLog - 19)
    for i = startIdx, #debugData.eventLog do
      local event = debugData.eventLog[i]
      local eventText = event.type or "Unknown"

      if event.penaltyType then
        eventText = eventText .. " (" .. event.penaltyType .. ")"
      end

      if event.points then
        eventText = eventText .. " [" .. event.points .. " pts]"
      end

      if event.time then
        eventText = eventText .. " at " .. formatTime(event.time)
      end

      local color = im.ImVec4(1, 1, 1, 1)
      if event.type == "penalty" then
        if event.points and event.points < 0 then
          color = im.ImVec4(0, 1, 0, 1) -- Green for bonuses
        else
          color = im.ImVec4(1, 0.5, 0, 1) -- Orange for penalties
        end
      elseif event.type == "checkpoint" then
        color = im.ImVec4(0, 1, 1, 1) -- Cyan for checkpoints
      end

      im.TextColored(color, eventText)
    end
  end
  im.Separator()
end

local function drawDebugWindow()
  if not debugWindowOpen or not enableDebugWindow then
    return
  end

  local shouldKeepOpen = im.Begin("Crawl Debug Window", im.BoolPtr(debugWindowOpen))
  if not shouldKeepOpen then
    debugWindowOpen = false
    im.End()
    return
  end

  if not debugData.trail or not debugData.crawlerData then
    im.Text("No active trail data")
    im.End()
    return
  end

  im.TextColored(im.ImVec4(1, 1, 0, 1), "=== TRAIL INFO ===")
  im.Text("Trail ID: " .. (debugData.trail.id or "Unknown"))
  im.Text("Trail Name: " .. (debugData.trail.name or "Unknown"))
  im.Text("Duration: " .. formatTime(debugData.currentTime))
  im.Text("Mission Trail: " .. (debugData.trail._isFromMission and "Yes" or "No"))
  im.Separator()

  im.TextColored(im.ImVec4(0, 1, 0, 1), "=== VEHICLE INFO ===")
  if debugData.crawlerData and debugData.crawlerData.dynamicData then
    local vd = debugData.crawlerData.dynamicData
    im.Text("Position: " .. string.format("%.2f, %.2f, %.2f", vd.vehPos.x, vd.vehPos.y, vd.vehPos.z))
    im.Text("Velocity: " .. string.format("%.2f m/s", vd.vehVelocity:length()))
    im.Text("Boundary Status: " .. getBoundaryStatus(debugData.crawlerData, debugData.trail))
  end
  im.Separator()

  drawPenaltySystem()
  drawInfractionData()
  drawRecoveryCheckpoint()
  drawBoundaryExitPoints()

  im.TextColored(im.ImVec4(0, 0, 1, 1), "=== NODES ===")
  local path = nil
  if debugData.trail.pathId then
    path = gameplay_crawl_saveSystem.getPathById(debugData.trail.pathId)
  end

  if path and path.nodes then
    local pathnodes = path.nodes
    im.Text("Total Nodes: " .. #pathnodes)
    im.Text("Current Index: " .. (debugData.currentPathnodeIndex or "N/A"))
    im.Text("Completed: " .. (debugData.completedCount or 0) .. "/" .. #pathnodes)
    im.Separator()

    if im.CollapsingHeader1("Node Details", im.TreeNodeFlags_DefaultOpen) then
      for i, pathnode in ipairs(pathnodes) do
        local isCompleted = debugData.completedPathnodes and debugData.completedPathnodes[i]
        local isCurrent = debugData.currentPathnodeIndex == i
        local isRecovery = pathnode.flags and pathnode.flags.isRecoveryCheckpoint
        local isBonus = pathnode.flags and pathnode.flags.isBonusCheckpoint

        local color = im.ImVec4(1, 1, 1, 1)
        if isCompleted then
          color = im.ImVec4(0, 1, 0, 1) -- Green for completed
        elseif isCurrent then
          color = im.ImVec4(1, 1, 0, 1) -- Yellow for current
        elseif isRecovery then
          color = im.ImVec4(0.2, 0.8, 0.2, 1) -- Green for recovery
        elseif isBonus then
          color = im.ImVec4(1, 0.8, 0, 1) -- Gold for bonus
        end

        local nodeText = string.format("%d. %s", i, pathnode.name or "Unknown")
        if isRecovery then
          nodeText = nodeText .. " [RECOVERY]"
        end
        if isBonus then
          nodeText = nodeText .. " [BONUS]"
        end

        im.TextColored(color, nodeText)
        im.SameLine()
        im.TextColored(color, string.format("(%.1f, %.1f, %.1f)", pathnode.pos.x, pathnode.pos.y, pathnode.pos.z))

        if isCompleted and debugData.pathnodeTimings and debugData.pathnodeTimings[i] then
          im.SameLine()
          im.TextColored(color, " - " .. formatTime(debugData.pathnodeTimings[i]))
        end
      end
    end
  else
    im.Text("No nodes available")
  end
  im.Separator()

  drawEventLog()

  im.TextColored(im.ImVec4(1, 0.5, 0, 1), "=== TRAIL STATUS ===")
  if debugData.isDisqualified then
    im.TextColored(im.ImVec4(1, 0, 0, 1), "DISQUALIFIED")
  elseif debugData.isCompleting then
    im.TextColored(im.ImVec4(0, 1, 0, 1), "COMPLETING - Waiting for results...")
  elseif debugData.isFinished then
    im.TextColored(im.ImVec4(0, 1, 0, 1), "FINISHED")
  else
    im.TextColored(im.ImVec4(1, 1, 0, 1), "ACTIVE")
  end

  im.End()
end

local function updateDebugData(crawlerId)
  if not enableDebugWindow then return end

  local utils = gameplay_crawl_utils
  if not utils then return end

  local state = utils.getCrawlState(crawlerId)
  if not state then return end

  debugData = {
    crawlerId = crawlerId,
    trail = state.trail,
    crawlerData = state.crawlerData,
    currentTime = state.currentTime,
    currentPathnodeIndex = state.currentPathnodeIndex,
    completedPathnodes = state.completedPathnodes,
    pathnodeTimings = state.pathnodeTimings,
    eventLog = state.eventLog,
    isCompleting = state.isCompleting,
    isFinished = state.isFinished,
    isDisqualified = state.isDisqualified,
    lastRecoveryCheckpoint = state.lastRecoveryCheckpoint,
    lastRecoveryCheckpointIndex = state.lastRecoveryCheckpointIndex,
    completedCount = 0
  }

  if debugData.completedPathnodes then
    for _ in pairs(debugData.completedPathnodes) do
      debugData.completedCount = debugData.completedCount + 1
    end
  end
end

local function onCrawlStarted(eventData)
  if not enableDebugWindow then return end

  debugWindowOpen = true
  log('D', logTag, 'Debug window opened for crawl')
end

local function onCrawlComplete(eventData)
  if debugData then
    debugData.isFinished = true
  end
  log('D', logTag, 'Crawl completed - debug data preserved')
end

local function onCrawlDisqualified(eventData)
  if debugData then
    debugData.isFinished = true
    debugData.isDisqualified = true
  end
  log('D', logTag, 'Crawl disqualified - debug data preserved')
end

local function onExtensionLoaded()
  debugWindowOpen = false
  debugData = {}
  log('D', logTag, 'Debug extension loaded')
end

local function onExtensionUnloaded()
  debugWindowOpen = false
  debugData = {}
  log('D', logTag, 'Debug extension unloaded')
end

local function onPreRender(dtReal, dtSim, dtRaw)
  if not enableDebugWindow then return end

  local utils = gameplay_crawl_utils
  if utils then
    local allStates = utils.getAllCrawlStates()
    if allStates then
      for crawlerId, state in pairs(allStates) do
        if state and state.active then
          updateDebugData(crawlerId)
          break
        end
      end
    end
  end

  drawDebugWindow()
end

M.setEnableDebugWindow = function(enabled)
  enableDebugWindow = enabled
  if not enabled then
    debugWindowOpen = false
    debugData = {}
  end
  log('D', logTag, 'Debug window ' .. (enabled and 'enabled' or 'disabled'))
end

M.getEnableDebugWindow = function()
  return enableDebugWindow
end

M.clearDebugData = function()
  debugData = {}
  log('D', logTag, 'Debug data cleared')
end

M.onCrawlStarted = onCrawlStarted
M.onCrawlComplete = onCrawlComplete
M.onCrawlDisqualified = onCrawlDisqualified
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onPreRender = onPreRender

return M