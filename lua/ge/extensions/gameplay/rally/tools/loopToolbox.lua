-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local Penalties = require('/lua/ge/extensions/gameplay/rally/loop/penalties')
local logTag = ''

local C = {}

-- UI Color constants
local colorGreen = im.ImVec4(0.2, 1.0, 0.2, 1.0)
local colorRed = im.ImVec4(0.9, 0.4, 0.4, 1.0)
local colorYellow = im.ImVec4(1.0, 0.8, 0.2, 1.0)
local colorLightBlue = im.ImVec4(0.5, 0.8, 1.0, 1.0)
local colorOrange = im.ImVec4(1.0, 0.6, 0.2, 1.0)

local settingsFilePath = "/settings/rally/loopToolbox.json"

function C:init()
  self.missionDropdownItems = {"<none>"}
  self.selectedMissionIndex = im.IntPtr(0)
  self.selectedMissionId = nil
  self.drawRoute = im.BoolPtr(true)
  self.drawLabels = im.BoolPtr(false)
  self.drawZOnTop = im.BoolPtr(true)
  self.drawSignboards = im.BoolPtr(false)
  self.drawVehBB = im.BoolPtr(false)
  self.drawLeadingPoint = im.BoolPtr(false)
  self.showDebugInfo = im.BoolPtr(false)
  self.signboards = {}
  self.syncedManager = nil

  -- Proximity tracking
  self.proximityDisplayDuration = 1.0  -- Show proximity data for 1 second after last update

  -- Test mode
  self.testModeEnabled = im.BoolPtr(false)
  self.testActiveStateIndex = im.IntPtr(0) -- 0=inactive, 1=vehicleProximity, 2=stageActive, 3=countdown
  self.skipLiaisonMessage = nil
  self.skipLiaisonSuccess = false

  self:loadSettings()
  self:refreshMissionList()
end

function C:saveSettings()
  local data = {
    selectedMissionId = self.selectedMissionId,
    drawRoute = self.drawRoute[0],
    drawLabels = self.drawLabels[0],
    drawZOnTop = self.drawZOnTop[0],
    drawSignboards = self.drawSignboards[0],
    drawVehBB = self.drawVehBB[0],
    drawLeadingPoint = self.drawLeadingPoint[0],
    showDebugInfo = self.showDebugInfo[0]
  }
  jsonWriteFile(settingsFilePath, data, true)
end

function C:loadSettings()
  self.settings = jsonReadFile(settingsFilePath)
  if self.settings then
    if self.settings.drawRoute ~= nil then
      self.drawRoute[0] = self.settings.drawRoute
    end
    if self.settings.drawLabels ~= nil then
      self.drawLabels[0] = self.settings.drawLabels
    end
    if self.settings.drawZOnTop ~= nil then
      self.drawZOnTop[0] = self.settings.drawZOnTop
    end
    if self.settings.drawSignboards ~= nil then
      self.drawSignboards[0] = self.settings.drawSignboards
      if self.drawSignboards[0] then
        self:findSignboards()
      end
    end
    if self.settings.drawVehBB ~= nil then
      self.drawVehBB[0] = self.settings.drawVehBB
    end
    if self.settings.drawLeadingPoint ~= nil then
      self.drawLeadingPoint[0] = self.settings.drawLeadingPoint
    end
    if self.settings.showDebugInfo ~= nil then
      self.showDebugInfo[0] = self.settings.showDebugInfo
    end
  else
    self.settings = {
        drawRoute = false,
        drawLabels = false,
        drawZOnTop = false,
        drawSignboards = false,
        drawVehBB = false,
        drawLeadingPoint = false,
        showDebugInfo = false
    }
  end
end

function C:applyManagerDrawFlags(manager)
  if not manager then return end
  manager:setDrawFlag('showDebugInfo', self.showDebugInfo[0])
  self.syncedManager = manager
end

function C:refreshMissionList()
  self.missionDropdownItems = {"<none>"}
  self.selectedMissionIndex[0] = 0
  self.selectedMissionId = nil

  local missions = gameplay_missions_missions.getMissionsByFilter({
    missionType = "rallyLoop",
    level = getCurrentLevelIdentifier()
  })

  for _, mission in ipairs(missions) do
    local translatedName = _tr(mission.name)
    local displayName = string.format("%s (%s)", translatedName, mission.id)
    table.insert(self.missionDropdownItems, displayName)
  end

  -- Load and restore previously selected mission
  local savedMissionId = self.settings.selectedMissionId
  if savedMissionId then
    for i, displayName in ipairs(self.missionDropdownItems) do
      local missionId = displayName:match("%((.+)%)$")
      if missionId == savedMissionId then
        self.selectedMissionIndex[0] = i - 1
        self.selectedMissionId = savedMissionId
        self.selectedMissionDir = RallyUtil.missionDirHelper(self.selectedMissionId)
        break
      end
    end
  end
end

function C:getSelectedMissionId()
  -- selectedMissionIndex[0] is 0-based (ImGui), Lua arrays are 1-based
  local luaIndex = self.selectedMissionIndex[0] + 1
  if luaIndex > 1 and luaIndex <= #self.missionDropdownItems then
    local selected = self.missionDropdownItems[luaIndex]
    local missionId = selected:match("%((.+)%)$")
    return missionId
  end
  return nil
end

function C:findSignboards()
  self.signboards = {}
  local seenById = {}
  local count = 0

  local function getObjectName(obj)
    local ok, name = pcall(function() return obj:getName() end)
    return ok and name or "unnamed"
  end

  local function getShapeName(obj)
    local ok, shapeName = pcall(function() return obj.shapeName end)
    if ok and shapeName and shapeName ~= "" then
      return shapeName
    end

    ok, shapeName = pcall(function() return obj:getField("shapeName", "") end)
    if ok and shapeName and shapeName ~= "" then
      return shapeName
    end

    return ""
  end

  local function getFlagValue(obj)
    local success, dynFields = pcall(function() return obj:getDynamicFields() end)
    if not (success and dynFields) then
      return false, ""
    end

    for _, fieldName in ipairs(dynFields) do
      if fieldName == "flag" then
        local ok, flagValue = pcall(function() return obj:getField("flag", "") end)
        return true, ok and flagValue or ""
      end
    end

    return false, ""
  end

  local function getObjectPosition(obj)
    local transformSuccess, transform = pcall(function() return obj:getTransform() end)
    if transformSuccess and transform then
      return vec3(transform:getColumn(3))
    end

    local posFieldSuccess, posField = pcall(function() return obj:getField("position", "") end)
    if posFieldSuccess and posField and posField ~= "" then
      local x, y, z = posField:match("([%d%.%-]+)%s+([%d%.%-]+)%s+([%d%.%-]+)")
      if x and y and z then
        return vec3(tonumber(x), tonumber(y), tonumber(z))
      end
    end

    return nil
  end

  local function cacheSignboard(obj)
    if not obj then return end
    obj = Sim.upcast(obj)
    if not obj then return end

    local objId = obj:getID()
    if objId and seenById[objId] then return end

    local objName = getObjectName(obj)
    local objShapeName = getShapeName(obj)

    -- Check if this object has a signboard shape
    local hasSignboardShape = objShapeName ~= "" and objShapeName:find("s_rally_signboard")

    -- Check if this object has a flag field
    local hasFlagField, flagValue = getFlagValue(obj)

    -- Cache object if it has signboard shape OR flag field
    if hasSignboardShape or hasFlagField then
      local objPos = getObjectPosition(obj)

      if objPos then
        table.insert(self.signboards, {
          id = objId,
          pos = objPos,
          flagValue = flagValue,
          name = objName,
          shapeName = objShapeName
        })
        if objId then
          seenById[objId] = true
        end
        count = count + 1
      else
        log('W', logTag, 'Object "' .. objName .. '" matched criteria but position could not be determined')
      end
    end
  end

  local function searchObject(obj, depth)
    if not obj then return end

    -- Upcast the object to ensure we have full access to its methods
    obj = Sim.upcast(obj)
    if not obj then return end

    cacheSignboard(obj)

    -- Packed prefab contents are covered by the TSStatic class scan below; recursion
    -- here stays bounded to regular/unpacked groups under MissionGroup.
    local objName = getObjectName(obj)
    local classOk, objClassName = pcall(function() return obj:getClassName() end)
    objClassName = classOk and objClassName or "unknown"
    local ok, unpackedPrefabValue = pcall(function() return obj:getField("unpacked_prefab", "") end)
    local isUnpackedPrefab = ok and unpackedPrefabValue == "1"
    local shouldRecurse = false

    if depth == 0 then
      -- Always recurse from MissionGroup to get top-level children
      shouldRecurse = true
    elseif depth < 4 and (isUnpackedPrefab or objName:find("Prefab") or objClassName == "SimGroup" or objClassName == "SimSet") then
      shouldRecurse = true
    end

    if shouldRecurse then
      -- Try both methods: size()/at() for some objects, getCount()/getObject() for SimGroup
      local objSize = nil
      local hasChildren = false
      local useSimGroupMethods = false

      -- First try size() method
      local success1, result1 = pcall(function() return obj:size() end)
      if success1 and result1 then
        hasChildren = true
        objSize = result1
      else
        -- Try getCount() method (used by SimGroup)
        local success2, result2 = pcall(function() return obj:getCount() end)

        if success2 and result2 and result2 > 0 then
          hasChildren = true
          objSize = result2
          useSimGroupMethods = true
        end
      end

      if hasChildren and objSize and objSize > 0 then
        -- Debug logging for Prefab*_unpacked objects
        -- if isPrefabUnpacked then
        --   log('I', logTag, '  -> Has ' .. objSize .. ' children, recursing...')
        -- end

        for i = 0, objSize - 1 do
          local childSuccess, child = nil, nil
          if useSimGroupMethods then
            childSuccess, child = pcall(function() return obj:getObject(i) end)
          else
            childSuccess, child = pcall(function() return obj:at(i) end)
          end

          if childSuccess and child then
            searchObject(child, depth + 1)
          end
        end
      end
    end
  end

  if scenetree.MissionGroup then
    searchObject(scenetree.MissionGroup, 0)
  else
    log('W', logTag, 'MissionGroup not found in scene tree')
  end

  -- Packed prefab instances can expose their children outside MissionGroup traversal.
  -- Keep the fallback narrow by scanning only loaded TSStatic objects and caching
  -- entries whose mesh/fields match rally signboards.
  for _, objName in ipairs(scenetree.findClassObjects('TSStatic') or {}) do
    cacheSignboard(scenetree.findObject(objName))
  end

  log('I', logTag, 'Found ' .. count .. ' signboard(s)')
  return count
end

function C:formatDuration(seconds, showSubseconds)
  -- Format duration in seconds to MM:SS or HH:MM:SS
  if not seconds then return "N/A" end

  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local secondsWithDecimal = seconds % 60  -- Keep the fractional part

  if showSubseconds then
    if hours > 0 then
      return string.format("%d:%02d:%04.1f", hours, minutes, secondsWithDecimal)
    else
      return string.format("%d:%04.1f", minutes, secondsWithDecimal)
    end
  else
    local secs = math.floor(seconds % 60)
    if hours > 0 then
      return string.format("%d:%02d:%02d", hours, minutes, secs)
    else
      return string.format("%d:%02d", minutes, secs)
    end
  end
end

function C:drawValidation(manager)
  im.TextColored(colorYellow, "Validation")

  local issues = manager:getValidationIssues()
  if not issues or #issues == 0 then
    if not manager:isScheduleValid() then
      im.TextColored(colorRed, "  Schedule validation failed")
      return true
    end
    im.TextColored(colorGreen, "  Validation: OK")
    return false
  end

  local hasBlockingIssues = false
  for _, issue in ipairs(issues) do
    hasBlockingIssues = hasBlockingIssues or issue.blocking
    local label = issue.label and (issue.label .. " | ") or ""
    local message = issue.message or "Validation failed"
    local text = "  " .. label .. tostring(issue.missionId or "<unknown>") .. " | " .. message
    if issue.hint then
      text = text .. " | " .. issue.hint
    end
    im.TextColored(issue.blocking and colorRed or colorOrange, text)
  end

  return hasBlockingIssues
end

function C:draw(manager)
  im.HeaderText("Rally Loop Debug")

  -- Mission selector dropdown with load/unload buttons
  im.PushItemWidth(300)
  local currentSelection = self.missionDropdownItems[self.selectedMissionIndex[0] + 1] or "<none>"
  if im.BeginCombo('##rallyLoopMission', currentSelection, im.ComboFlags_HeightLarge) then
    for i, missionName in ipairs(self.missionDropdownItems) do
      if im.Selectable1(missionName, i == self.selectedMissionIndex[0] + 1) then
        self.selectedMissionIndex[0] = i - 1
        self.selectedMissionId = self:getSelectedMissionId()
        self.selectedMissionDir = RallyUtil.missionDirHelper(self.selectedMissionId)
        self:saveSettings()
      end
    end
    im.EndCombo()
  end
  im.PopItemWidth()

  im.SameLine()
  if im.Button("Load") then
    gameplay_rallyLoop.setup(self.selectedMissionId, self.selectedMissionDir)
    self:applyManagerDrawFlags(gameplay_rallyLoop.getManager())
  end

  im.Spacing()

  if im.Button("Unload Mission") then
    gameplay_rallyLoop.unload()
  end

  im.SameLine()

  if im.Button("Unload Extension") then
    if extensions.isExtensionLoaded('gameplay_rallyLoop') then
      extensions.unload('gameplay_rallyLoop')
    end
  end

  if not manager then
    im.Text("No rally loop manager active")
    return
  end

  -- Skip button - enabled if either TC skip or countdown skip is available
  im.SameLine()
  local skipEnabled = manager:canSkip()
  if not skipEnabled then
    im.BeginDisabled()
  end
  if im.Button("Skip") then
    extensions.hook('onGameplayInteract')
  end
  if not skipEnabled then
    im.EndDisabled()
  end

  -- Time control buttons
  im.SameLine()
  if im.Button("-1m") then
    manager:adjustClock(-60)
  end
  im.SameLine()
  if im.Button("-10s") then
    manager:adjustClock(-10)
  end
  im.SameLine()
  if im.Button("+10s") then
    manager:adjustClock(10)
  end
  im.SameLine()
  if im.Button("+1m") then
    manager:adjustClock(60)
  end
  im.SameLine()
  local isPaused = manager:getClockPaused()
  if isPaused then
    im.PushStyleColor2(im.Col_Button, im.ImVec4(0.8, 0.4, 0.1, 1.0))
    im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(0.9, 0.5, 0.15, 1.0))
    im.PushStyleColor2(im.Col_ButtonActive, im.ImVec4(0.6, 0.3, 0.05, 1.0))
  end
  if im.Button(isPaused and "Resume Clock" or "Pause Clock") then
    manager:setClockPaused(not isPaused)
  end
  if isPaused then
    im.PopStyleColor(3)
  end

  if self.syncedManager ~= manager then
    self:applyManagerDrawFlags(manager)
  end

  -- Keep the checkbox reflecting the active manager after the saved value has been applied.
  self.showDebugInfo[0] = manager:getDrawFlag('showDebugInfo')

  im.Spacing()

  -- Mission info
  im.TextColored(colorYellow, "Mission Info")
  im.Text("  Mission ID: " .. tostring(manager.missionId or "N/A"))
  im.Text("  Mission Dir: " .. tostring(manager.missionDir or "N/A"))

  im.Spacing()

  -- Proximity data - unified display
  local proximityData = manager.currentVehicleProximity

  im.TextColored(colorYellow, "Proximity Data")

  if not proximityData then
    -- Show "no data" and empty progress bar
    im.Text("  no data")
    im.ProgressBar(0, im.ImVec2(200, 0), "")
  else
    -- Condensed to one line: Near status | Distance | Frozen status | Progress bar
    local statusColor = proximityData.isNear and colorGreen or colorRed
    im.TextColored(statusColor, string.format("Near: %s | Dist: %.2fm | Frozen: %s", tostring(proximityData.isNear), proximityData.distance or 0, tostring(proximityData.isFrozen or false)))
    local progress = (proximityData.timer or 0) / math.max(1e-12, proximityData.duration or 1)
    im.ProgressBar(progress, im.ImVec2(200, 0), string.format("%.1f/%.1fs", proximityData.timer or 0, proximityData.duration or 0))
  end

  im.Spacing()

  -- Mission Progress
  im.TextColored(colorYellow, "Runtime Info")
  local currentMissionId = manager:getCurrentMissionId()
  local foregroundMissionId = gameplay_missions_missionManager.getForegroundMissionId()
  local missionsMatch = (currentMissionId == foregroundMissionId)

  im.Text("  Current Index: " .. tostring(manager.currentMissionIndex) .. " / " .. tostring(#manager.missionSequence))
  if not missionsMatch then
    im.SameLine()
    im.TextColored(colorRed, " [MISMATCH]")
  end

  if currentMissionId then
    if missionsMatch then
      im.Text("  Loop Mission ID: " .. currentMissionId)
    else
      im.TextColored(colorRed, "  Loop Mission ID: " .. currentMissionId)
    end
  else
    im.Text("  Loop Mission ID: <none>")
  end

  if foregroundMissionId then
    if missionsMatch then
      im.Text("  Missions System Mission ID: " .. foregroundMissionId)
    else
      im.TextColored(colorRed, "  Missions System Mission ID: " .. foregroundMissionId)
    end
  else
    im.Text("  Missions System Mission ID: <none>")
  end

  -- Race Data Summary
  -- if gameplay_rally and gameplay_rally.getRallyManager then
  --   local rallyMgr = gameplay_rally.getRallyManager()
  --   if rallyMgr then
  --     local raceDataSummary = rallyMgr:getRaceDataSummary()
  --     if raceDataSummary then
  --       im.Spacing()
  --       im.Separator()
  --       im.Spacing()

  --       im.TextColored(colorYellow, "Stage Time")

  --       -- Current time
  --       local timeStr = self:formatDuration(raceDataSummary.currentTime, true)
  --       im.SetWindowFontScale(1.3)
  --       if raceDataSummary.isComplete then
  --         im.TextColored(colorLightBlue, "  Final Time: " .. timeStr)
  --       else
  --         im.Text("  Current Time: " .. timeStr)
  --       end
  --       im.SetWindowFontScale(1.0)

  --       -- Split times
  --       -- if #raceDataSummary.splits > 0 then
  --         -- im.Spacing()
  --         -- im.TextColored(colorYellow, "Splits")
  --         -- for i, split in ipairs(raceDataSummary.splits) do
  --         --   local splitTimeStr = self:formatDuration(split.time, true)
  --         --   im.Text(string.format("  %s: %s", split.name, splitTimeStr))
  --         -- end
  --       -- end
  --     end
  --   end
  -- end

  im.Spacing()
  im.Separator()
  im.Spacing()

  -- Settings
  im.TextColored(colorYellow, "Draw Settings")
  if im.Checkbox("Route", self.drawRoute) then
    self:saveSettings()
  end
  im.SameLine()
  if im.Checkbox("Labels", self.drawLabels) then
    self:saveSettings()
  end
  im.SameLine()
  if im.Checkbox("Z On Top", self.drawZOnTop) then
    self:saveSettings()
  end
  im.SameLine()
  if im.Checkbox("Signboards", self.drawSignboards) then
    local count = self:findSignboards()
    log('D', logTag, 'Found ' .. count .. ' signboards')
    self:saveSettings()
  end
  -- if im.Checkbox("Vehicle BB", self.drawVehBB) then
  --   self:saveSettings()
  -- end
  -- im.SameLine()
  -- if im.Checkbox("Leading Point", self.drawLeadingPoint) then
  --   self:saveSettings()
  -- end
  im.SameLine()
  if im.Checkbox("Show Debug Info", self.showDebugInfo) then
    manager:setDrawFlag('showDebugInfo', self.showDebugInfo[0])
    self:saveSettings()
  end

  -- Draw vehicle debug visuals
  if self.drawVehBB[0] then
    RallyUtil.drawVehBB(getPlayerVehicle(0):getID())
  end
  if self.drawLeadingPoint[0] then
    RallyUtil.drawVehLeadingPoint(getPlayerVehicle(0):getID())
  end

  -- im.Spacing()

  -- Signboard finder
  -- if im.Button("Find Signboards") then
  --   local count = self:findSignboards()
  --   log('I', logTag, 'Cached ' .. count .. ' signboards')
  -- end
  -- im.SameLine()
  -- im.Text("Found: " .. tostring(#self.signboards))

  im.Spacing()
  im.Separator()
  im.Spacing()

  -- Rally Loop Structure Visualization
  im.TextColored(colorYellow, "Overview")

  -- Time of Day
  local timeStr = manager:getTimeOfDayFormatted()
  im.Text("  Environment Time of Day: " .. timeStr)

  local timeStr = manager:getEnvironmentStartTimeFormatted()
  im.Text("  Environment Start Time: " .. timeStr)

  -- Rally Start Time
  local rallyStartStr1 = manager:getRallyStartTimeFormatted()
  local rallyStartStr2 = ""
  local rallyStartDuration = manager:getRallyStartDurationSecs()
  local rallyPreStartAllocatedDuration = manager:getRallyPreStartAllocatedDurationSecs()
  if rallyStartDuration and rallyPreStartAllocatedDuration then
    rallyStartStr1 = rallyStartStr1 .. " / +" .. self:formatDuration(rallyStartDuration) .. " from Env Start"
    rallyStartStr2 = "+" .. self:formatDuration(rallyPreStartAllocatedDuration) .. " pre-start allocated"
  end
  im.Text("  Rally Start Time:")
  im.Text("    " .. rallyStartStr2)
  im.Text("    " .. rallyStartStr1)

  im.Spacing()
  im.Separator()
  im.Spacing()

  -- Distance Totals
  local totalSSKm = manager:getTotalSSDistanceKm()
  local totalRoadSectionKm = manager:getTotalRoadSectionDistanceKm()
  local totalKm = manager:getTotalDistanceKm()
  im.Text(string.format("  SS Distance: %.2f km", totalSSKm))
  im.Text(string.format("  Liaison Distance: %.2f km", totalRoadSectionKm))
  im.Text(string.format("  Total Distance: %.2f km", totalKm))

  im.Spacing()
  im.Separator()
  im.Spacing()

  -- Total SS Time
  local totalTime = manager:getTotalTime()
  if totalTime then
    local totalTimeStr = self:formatDuration(totalTime, true, true)
    im.SetWindowFontScale(1.3)
    im.TextColored(colorLightBlue, "  Total Time: " .. totalTimeStr)
    im.SetWindowFontScale(1.0)
  end

  -- Total Penalty
  local totalPenalty = manager:getTotalPenalty()
  if totalPenalty then
    im.SetWindowFontScale(1.3)
    im.TextColored(colorRed, string.format("  Total Penalty: +%ds", totalPenalty))
    im.SetWindowFontScale(1.0)
  end

  im.Spacing()
  im.Separator()
  im.Spacing()

  local hasBlockingValidationIssues = self:drawValidation(manager)
  if hasBlockingValidationIssues or not manager:isScheduleValid() then
    im.Spacing()
    im.Separator()
    im.Spacing()
    im.TextColored(colorYellow, "Schedule")
    im.TextColored(colorRed, "  Schedule invalid")
    return
  end

  im.Spacing()
  im.Separator()
  im.Spacing()

  im.TextColored(colorYellow, "Schedule")

  -- Wall Clock Time
  local wallClockStr = manager:getWallClockTimeFormatted()
  im.SetWindowFontScale(1.3)
  im.Text("  Wall Clock Time: " .. wallClockStr)

  -- Epoch Time
  local epochTime = manager:getEpochTime()
  local epochSign = epochTime >= 0 and "+" or "-"
  local epochStr = self:formatDuration(math.abs(epochTime), true)
  im.Text("  Epoch Time: " .. epochSign .. epochStr)
  im.SetWindowFontScale(1.0)

  im.Spacing()
  im.Separator()
  im.Spacing()

  -- Get current mission ID for highlighting
  local currentMissionId = manager:getCurrentMissionId()

  -- Get the schedule from the manager
  local schedule = manager:getSchedule()
  if not schedule or #schedule == 0 then
    im.TextDisabled("  No schedule calculated")
    return
  end

  -- Iterate through schedule and display each mission
  for i, entry in ipairs(schedule) do
    -- Get mission name
    local mission = nil
    local missionName = entry.missionId

    -- Only lookup mission if it's an actual mission (not serviceOut/serviceIn placeholders)
    if not entry.notActualMission then
      mission = gameplay_missions_missions.getMissionById(entry.missionId)
      if mission then
        missionName = _tr(mission.name)
      end
    end

    -- Build display name with appropriate prefix
    local displayName = missionName
    if entry.ssLabel then
      -- This is a special stage
      displayName = "SS"..entry.ssLabel .. " | " .. missionName
    elseif entry.roadSectionLabel then
      -- This is a road section
      displayName = entry.roadSectionLabel .. " | " .. missionName
    end

    -- Append distance to mission name if it exists
    if entry.distanceKm then
      displayName = displayName .. string.format(" | %.2f km", entry.distanceKm)
    end

    -- Display pre-calculated durations from schedule
    if entry.missionType == 'serviceOut' or entry.missionType == 'serviceIn' then
      -- Service missions: show single duration
      if entry.durationSecs then
        displayName = displayName .. " | " .. self:formatDuration(entry.durationSecs) .. " alloc"
      end
    elseif entry.ssLabel then
      -- SS stage: show transition and stage times
      if entry.transitionDurationSecs and entry.sectionDurationSecs then
        displayName = displayName .. " | TC→start: " .. self:formatDuration(entry.transitionDurationSecs) .. ", SS: " .. self:formatDuration(entry.sectionDurationSecs) .. " alloc"
      elseif entry.sectionDurationSecs then
        displayName = displayName .. " | " .. self:formatDuration(entry.sectionDurationSecs) .. " alloc"
      end
    elseif entry.roadSectionLabel then
      -- Road section: show section duration
      if entry.sectionDurationSecs then
        displayName = displayName .. " | " .. self:formatDuration(entry.sectionDurationSecs) .. " alloc"
      end
    end

    -- Wrap in parentheses if this mission has no events
    if entry.noEvents then
      displayName = "(" .. displayName .. ")"
    end

    -- Display mission name
    if entry.missionId == currentMissionId then
      im.TextColored(colorGreen, "  " .. displayName)
    else
      im.Text("  " .. displayName)
    end

    -- Add tooltip showing mission ID
    if im.IsItemHovered() then
      im.BeginTooltip()
      im.Text(entry.missionId)
      im.EndTooltip()
    end

    -- Display each event on its own line with time
    local events = manager:getEvents()
    local nextEventIndex = manager:getNextEventIndex()
    if events then
      for eventIdx, event in ipairs(events) do
      -- Only display events for this mission
      if event.missionIndex == i then
        -- Convert event time from rally epoch to wall clock for display
        local wallClockTime = manager:epochToWallClock(event.time)
        local timeStr = wallClockTime and manager:formatTimeFromSecondsString(wallClockTime, false, false) or "N/A"
        local durationStr = ""
        if event.time then
          -- event.time is already in rally epoch (relative to rally start)
          durationStr = " / +" .. self:formatDuration(event.time)
        end

        local eventText = timeStr .. durationStr .. " - " .. event.label

        -- Add reschedule count if event was rescheduled
        if event.rescheduleCount and event.rescheduleCount > 0 then
          eventText = eventText .. string.format(" (rescheduled %dx)", event.rescheduleCount)
        end

        -- Add opening parenthesis if hidden, then add indentation
        if event.hideTimecardEntry then
          eventText = "    (" .. eventText
        else
          eventText = "    " .. eventText
        end

        -- Track whether we need to add closing paren and what color
        local needClosingParen = event.hideTimecardEntry
        local eventColor = nil

        -- Display event text - highlight next event in green
        if eventIdx == nextEventIndex and event.missionId == currentMissionId then
          -- Next event in current mission -> green
          eventColor = colorGreen
          im.TextColored(colorGreen, eventText)

          -- Show early/late/on-time status for current event (only for visible timecard entries)
          if event.time then
            local currentEpochTime = manager:getEpochTime()
            local timeDiff = currentEpochTime - event.time
            local sign = timeDiff >= 0 and "+" or "-"
            local diffStr = self:formatDuration(math.abs(timeDiff))
            local currentTimeStr = sign..diffStr
            local timingResult = Penalties.getTimingStatus(timeDiff)
            local statusText = " " .. timingResult.status
            if timingResult.totalPenalty > 0 then
              statusText = statusText .. string.format(", would be +%ds penalty", timingResult.totalPenalty)
            end

            -- Color: orange for penalty, blue for no penalty
            local statusColor = timingResult.hasPenalty and colorOrange or colorLightBlue

            im.SameLine()
            im.TextColored(colorLightBlue, currentTimeStr)
            if not event.hideTimecardEntry then
              im.SameLine()
              im.TextColored(statusColor, statusText)
            end
          end
        else
          -- All other events -> normal
          im.Text(eventText)
        end

        -- Add timecard entry on same line if event is completed
        if event.timecardEntry and event.timecardEntry.actualTime then
          im.SameLine()

          local actualTime = event.timecardEntry.actualTime
          -- Convert actual time from rally epoch to wall clock for display
          local actualWallClock = manager:epochToWallClock(actualTime)
          local actualTimeStr = actualWallClock and manager:formatTimeFromSecondsString(actualWallClock, true, false) or "N/A"
          local timecardText = "Timecard: " .. actualTimeStr

          -- Add time difference and status
          if event.timecardEntry.timingResult then
            local timeDiff = event.timecardEntry.timeDiff
            local sign = timeDiff >= 0 and "+" or "-"
            local diffStr = self:formatDuration(math.abs(timeDiff))
            local timingResult = event.timecardEntry.timingResult
            timecardText = timecardText .. ", " .. sign .. diffStr .. " (" .. timingResult.status .. ")"

            -- Add penalty if present
            if timingResult.totalPenalty > 0 then
              timecardText = timecardText .. string.format(" +%ds penalty", timingResult.totalPenalty)
            end
          elseif event.timecardEntry.timeDiff then
            -- Fallback for old format without timingResult
            local timeDiff = event.timecardEntry.timeDiff
            local sign = timeDiff >= 0 and "+" or "-"
            local diffStr = self:formatDuration(math.abs(timeDiff))
            timecardText = timecardText .. ", " .. sign .. diffStr
          end

          -- Color based on penalty status
          local timecardColor = colorLightBlue
          if event.timecardEntry.timingResult and event.timecardEntry.timingResult.hasPenalty then
            timecardColor = colorRed
          end

          -- Display timecard entry
          im.TextColored(timecardColor, timecardText)
        end

        -- Add closing parenthesis if needed, matching the color of the opening paren
        if needClosingParen then
          im.SameLine()
          if eventColor then
            im.TextColored(eventColor, ")")
          else
            im.Text(")")
          end
        end

        -- Add stage time on new line if present (from either timecard entry or stageTime)
        local stageTimeSecs = nil
        local falseStartPenalty = nil
        if event.timecardEntry and event.timecardEntry.stageTimeSecs then
          stageTimeSecs = event.timecardEntry.stageTimeSecs
          falseStartPenalty = event.timecardEntry.falseStartPenalty
        elseif event.stageTime and event.stageTime.actualTime then
          stageTimeSecs = event.stageTime.actualTime
        end

        if stageTimeSecs then
          local stageTimeStr = self:formatDuration(stageTimeSecs, true)
          local stageText = "      SS Time: " .. stageTimeStr
          im.TextColored(colorLightBlue, stageText)

          -- Show false start penalty if present
          if falseStartPenalty and falseStartPenalty > 0 then
            im.SameLine()
            im.TextColored(colorRed, string.format("  +%ds false start", falseStartPenalty))
          end
        end

        -- Add tooltip showing mission ID and event details
        if im.IsItemHovered() then
          im.BeginTooltip()
          im.Text("Mission: " .. event.missionId)
          im.Text("Event Type: " .. event.type)
          im.Text("Label: " .. event.label)
          if event.spName then
            im.Text("Start Position: " .. event.spName)
          end
          im.EndTooltip()
        end
      end
      end
    end

    -- Add spacing between entries for readability
    if i < #schedule then
      im.Spacing()
      im.Separator()
      im.Spacing()
    end
  end

  -- Service variables (camera controls)
  -- im.TextColored(colorYellow, "Camera Controls")

  -- -- Service stall focus button
  -- local stallPos = manager.fgVariables and manager.fgVariables.serviceStallPos
  -- if stallPos and type(stallPos) == "table" then
  --   if im.Button("Focus on Service Stall") then
  --     local center = vec3(stallPos[1], stallPos[2], stallPos[3])
  --     local rot = core_camera.getQuat()
  --     local pos = center + rot * vec3(0, -15, 0)
  --     local camRot = quatFromDir(center - pos)
  --     core_camera.setPosRot(0, pos.x, pos.y, pos.z, camRot.x, camRot.y, camRot.z, camRot.w)
  --   end
  -- end

  -- -- Service out trigger focus button
  -- local outTriggerPos = manager.fgVariables and manager.fgVariables.serviceOutTriggerPos
  -- if outTriggerPos and type(outTriggerPos) == "table" then
  --   if im.Button("Focus on Service Out Trigger") then
  --     local center = vec3(outTriggerPos[1], outTriggerPos[2], outTriggerPos[3])
  --     local rot = core_camera.getQuat()
  --     local pos = center + rot * vec3(0, -15, 0)
  --     local camRot = quatFromDir(center - pos)
  --     core_camera.setPosRot(0, pos.x, pos.y, pos.z, camRot.x, camRot.y, camRot.z, camRot.w)
  --   end
  -- end


  if self.drawRoute[0] or self.drawLabels[0] then
    self:drawDebug()
  end

  if self.drawSignboards[0] then
    self:drawSignboardsDebug()
  end

  -- Testing section
  im.Spacing()
  im.Separator()
  im.Spacing()

  if im.CollapsingHeader1("Testing", im.TreeNodeFlags_DefaultClosed) then
    -- Test Mode toggle button
    local testModeEnabled = manager and manager:getTestMode() or false
    local buttonText = testModeEnabled and "Disable Test Mode" or "Enable Test Mode"

    if im.Button(buttonText) then
      if manager then
        manager:setTestMode(not testModeEnabled)
      end
    end

    im.Spacing()

    local skipLiaisonEnabled = manager and manager:isInRoadSection()
    if not skipLiaisonEnabled then
      im.BeginDisabled()
    end
    if im.Button("Skip Liaison") then
      local ok, reason = manager:skipLiaisonForTesting()
      self.skipLiaisonSuccess = ok
      if ok then
        self.skipLiaisonMessage = "Skip Liaison: moved to TC_out approach"
        log('I', logTag, self.skipLiaisonMessage)
      else
        self.skipLiaisonMessage = "Skip Liaison failed: " .. tostring(reason)
        log('W', logTag, self.skipLiaisonMessage)
      end
    end
    if not skipLiaisonEnabled then
      im.EndDisabled()
    end
    if self.skipLiaisonMessage then
      im.TextColored(self.skipLiaisonSuccess and colorGreen or colorRed, self.skipLiaisonMessage)
    end

    im.Spacing()

    -- Radio buttons for active states (only enabled when test mode is on)
    if not testModeEnabled then
      im.BeginDisabled()
    end

    im.Text("Active State:")
    if im.RadioButton2("Inactive", self.testActiveStateIndex, 0) then
      if manager then
        manager:setTestActiveState(RallyUtil.activeState_inactive)
      end
    end
    if im.RadioButton2("Vehicle Proximity", self.testActiveStateIndex, 1) then
      if manager then
        manager:setTestActiveState(RallyUtil.activeState_vehicleProximity)
      end
    end
    if im.RadioButton2("Stage Active", self.testActiveStateIndex, 2) then
      if manager then
        manager:setTestActiveState(RallyUtil.activeState_stageActive)
      end
    end
    if im.RadioButton2("Countdown", self.testActiveStateIndex, 3) then
      if manager then
        manager:setTestActiveState(RallyUtil.activeState_countdown)
      end
    end

    if not testModeEnabled then
      im.EndDisabled()
    end
  end
end

function C:drawDebug()
  if not extensions.isExtensionLoaded('gameplay_rallyLoop') then return end
  gameplay_rallyLoop.drawDebug(self.drawZOnTop[0], self.drawRoute[0], self.drawLabels[0])
end

function C:drawSignboardsDebug()
  -- Draw cached signboards
  for _, signboard in ipairs(self.signboards) do
    local success = pcall(function()
      local pos = signboard.pos
      if signboard.id then
        local obj = scenetree.findObjectById(signboard.id)
        if obj then
          local posOk, objectPos = pcall(function() return obj:getPosition() end)
          if posOk and objectPos then
            pos = objectPos
          end
        end
      end

      if pos then
        -- Draw a sphere at the signboard location
        -- debugDrawer:drawSphere(pos, 0.5, ColorF(0.2, 0.5, 1.0, 0.8))
        -- Draw the flag value as text
        local shapeName = signboard.shapeName or ""
        local shortName = shapeName:match("s_rally_signboard_(.+)%.dae") or signboard.name
        -- local displayText = shortName .. ": " .. signboard.flagValue
        local displayText = shortName
        debugDrawer:drawTextAdvanced(
          pos,
          String(displayText),
          ColorF(1, 1, 1, 1),
          true,
          false,
          ColorI(50, 100, 200, 255),
          false,
          false
        )
      end
    end)
    if not success then
      log('W', logTag, 'Failed to draw signboard with ID ' .. tostring(signboard.id))
    end
  end
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
