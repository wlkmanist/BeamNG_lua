-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "drag_timeslip"

M.dependencies = {'gameplay_drag_saveSystem'}

local treeNames = {[".400"] = "Pro Tree", [".500"] = "Sportsman Tree"}

local function getReactionTimerValueForRacer(racer)
  return gameplay_drag_times.getReactionTimerValue(racer)
end

local function buildTimeslipRows(timerConfig)
  local rows = {}
  table.insert(rows, { key = "laneName", labelKey = "missions.missions.dragRace.userSettings.lane" })
  table.insert(rows, { key = nil })
  table.insert(rows, { key = "dial", label = "DIAL" })

  local distanceTimers = {}
  local velocityByDist = {}

  for _, t in ipairs(timerConfig) do
    if t.type == "velocity" then
      velocityByDist[t.distance or 0] = t
    else
      table.insert(distanceTimers, t)
    end
  end

  table.sort(distanceTimers, function(a, b) return (a.distance or 0) < (b.distance or 0) end)

  for _, t in ipairs(distanceTimers) do
    table.insert(rows, { key = t.id, label = t.shortLabel or t.label })
    local vel = velocityByDist[t.distance or 0]
    if vel then
      table.insert(rows, { key = vel.id .. "_kmh", label = "KM/H" })
      table.insert(rows, { key = vel.id .. "_mph", label = "MPH" })
    end
  end

  table.insert(rows, { key = "dialDiff", label = "DIFF" })
  return rows
end

function M.createTimeslipData()
  local currentDragData = gameplay_drag_core.getData()
  if not currentDragData or not next(currentDragData) then
    log("E", logTag, "No drag data found, cannot create timeslip data")
    return nil
  end

  local rawData = {}
  rawData.stripInfo = {
    stripName = currentDragData.stripInfo and currentDragData.stripInfo.stripName or "Drag Strip",
    levelName = core_levels.getLevelByName(getCurrentLevelIdentifier()).title,
    dateTime = os.date(currentDragData.stripInfo and currentDragData.stripInfo.dateFormat or "%a %m/%d/%Y %I:%M:%S %p"),
    timestamp = os.time(),
    tree = treeNames[currentDragData.prefabs.christmasTree.treeType],
  }
  rawData.env = {
    tempK = core_environment.getTemperatureK(),
    tempC = core_environment.getTemperatureK() - 273.15,
    tempF = (core_environment.getTemperatureK() - 273.15) * (9/5) + 32,
    customGrav = math.abs(core_environment.getGravity() - 9.81) > 0.01,
    gravity = string.format("%0.2f m/s²", math.abs(core_environment.getGravity())),
  }
  rawData.dragType = currentDragData.dragType
  rawData.laneCount = currentDragData.strip and currentDragData.strip.lanes and #currentDragData.strip.lanes or 2

  local timerConfig = currentDragData.timers or gameplay_drag_saveSystem.DEFAULT_TIMERS
  local importantId = currentDragData.importantTimerId or "time_1_4"
  rawData.racerInfos = {}
  rawData.timerConfig = timerConfig
  rawData.timeslipRows = buildTimeslipRows(timerConfig)
  rawData.importantTimerId = importantId

  local isMP = false
  local networkTimers = {}
  local drag = gameplay_drag_core.getDragGamemode()
  if drag and drag.isMultiplayer and drag.isMultiplayer() then
    isMP = true
    local race = drag.getActiveDragRace and drag.getActiveDragRace()
    if race and race.timerValues and race.players then
      for pid, tvs in pairs(race.timerValues) do
        local pd = race.players[pid]
        if pd and pd.vehicleId then
          networkTimers[pd.vehicleId] = tvs
        end
      end
    end
  end

  for id, racer in pairs(currentDragData.racers) do
    local currentVehicle = core_vehicles.getVehicleDetails(id)
    local vehicleConfig = currentVehicle and currentVehicle.configs or {}
    local timerEntries = {}
    local importantVal = 0
    local dialVal = (racer.timers and racer.timers.dial and racer.timers.dial.value) or 0
    local reactionVal = getReactionTimerValueForRacer(racer)
    local netTimers = isMP and networkTimers[id] or nil

    for _, t in ipairs(timerConfig) do
      local timerId = t.id or ("timer_" .. #timerEntries)
      local val
      if netTimers and netTimers[timerId] then
        val = netTimers[timerId]
      else
        local timerObj = racer.timers and racer.timers[timerId]
        if timerObj then
          val = timerObj.isSet and timerObj.value or -1
        else
          val = -1
        end
      end
      if timerId == importantId then
        importantVal = val
      end
      local entry = {
        id = timerId,
        label = t.label or timerId,
        shortLabel = t.shortLabel,
        value = val,
        important = (t.important == true),
      }
      if val < 0 then
        if t.type == "velocity" then
          entry.value_kmh = "-"
          entry.value_mph = "-"
        else
          entry.valueStr = "-"
        end
      elseif t.type == "velocity" then
        entry.value_kmh = string.format("%0.3f", val * 3.6)
        entry.value_mph = string.format("%0.3f", val * 2.23694)
      else
        entry.valueStr = string.format("%0.3f", val)
      end
      table.insert(timerEntries, entry)
    end

    local displayName = racer.niceName
    if not displayName and id and id ~= -1 then
      local details = core_vehicles.getVehicleDetails(id)
      if details and details.model then
        displayName = (details.model.Brand or "") .. " " .. (details.configs.Name or "Unknown")
      end
    end
    if drag and drag.isMultiplayer and drag.isMultiplayer() and drag.getActiveDragRace then
      local race = drag.getActiveDragRace()
      if race and race.players then
        for _, playerData in pairs(race.players) do
          if playerData.vehicleId == id or (playerData.lane and playerData.lane == racer.lane) then
            if not displayName and playerData.configName then
              displayName = playerData.configName
            end
            if playerData.persona then
              displayName = (displayName or "Unknown") .. " - " .. playerData.persona
            end
            break
          end
        end
      end
    end
    displayName = displayName or "Unknown"

    local timersForUi = {}
    for _, e in ipairs(timerEntries) do
      timersForUi[e.id] = e.valueStr or "-"
    end
    if currentDragData.dragType == "bracketRace" and dialVal ~= nil and dialVal >= 0 then
      timersForUi.dial = { type = "dialTimer", value = dialVal, isSet = true }
    end

    local displayValues = {}
    displayValues.laneName = currentDragData.strip and currentDragData.strip.lanes and currentDragData.strip.lanes[racer.lane] and currentDragData.strip.lanes[racer.lane].longName or ("Lane " .. tostring(racer.lane))
    if currentDragData.dragType == "bracketRace" and dialVal ~= nil and dialVal >= 0 then
      displayValues.dial = string.format("%0.3f", dialVal)
    else
      displayValues.dial = "-"
    end
    displayValues.reactionTime = reactionVal >= 0 and string.format("%0.3f", reactionVal) or "-"
    for _, e in ipairs(timerEntries) do
      if e.value_kmh then
        displayValues[e.id .. "_kmh"] = e.value_kmh
        displayValues[e.id .. "_mph"] = e.value_mph
      else
        displayValues[e.id] = e.valueStr or "-"
      end
    end

    local rewards = gameplay_drag_core.setCareerRewards() or {}
    if type(rewards) ~= "table" then rewards = {} end

    local info = {
      vehId = id,
      displayName = displayName,
      name = displayName,
      stock = racer.stock and "Stock" or "Modified",
      licenseText = racer.licenseText,
      lane = currentDragData.strip and currentDragData.strip.lanes and currentDragData.strip.lanes[racer.lane] and currentDragData.strip.lanes[racer.lane].longName or ("Lane " .. tostring(racer.lane)),
      laneNum = racer.lane,
      finalTime = importantVal,
      reactionTime = reactionVal,
      rewards = rewards,
      dialDiff = (importantVal + reactionVal) - dialVal,
      disqualification = (racer.isDisqualified ~= nil and racer.isDisqualified) or racer.isDesqualified,
      brand = (currentVehicle and currentVehicle.model and currentVehicle.model.Brand) or "Unknown",
      country = (currentVehicle and currentVehicle.model and currentVehicle.model.Country) or "Unknown",
      drivetrain = vehicleConfig.Drivetrain or "Unknown",
      fuelType = vehicleConfig["Fuel Type"] or "Unknown",
      transmission = vehicleConfig.Transmission or "Unknown",
      configType = vehicleConfig["Config Type"] or "Unknown",
      inductionType = vehicleConfig["Induction Type"] or "Unknown",
      timerEntries = timerEntries,
      timers = timersForUi,
      displayValues = displayValues,
    }
    table.insert(rawData.racerInfos, info)
  end
  table.sort(rawData.racerInfos, function(a, b) return a.laneNum > b.laneNum end)

  for _, info in ipairs(rawData.racerInfos) do
    if info.dialDiff ~= nil then
      local dd = info.dialDiff
      info.dialDiffStr = (dd > 0 and "+" or "") .. string.format("%0.3f", dd)
      if info.displayValues and rawData.dragType == "bracketRace" then
        info.displayValues.dialDiff = info.dialDiffStr
      end
    end
    if info.displayValues then
      if not info.displayValues.dialDiff then info.displayValues.dialDiff = "-" end
      local et = tonumber(info.finalTime) or 0
      local rt = tonumber(info.reactionTime) or 0
      if et > 0 then
        info.displayValues.etRt = string.format("%0.3f", et + rt) .. "s"
      end
    end
  end

  if #rawData.racerInfos == 2 then
    local a, b = rawData.racerInfos[1], rawData.racerInfos[2]
    for _, pair in ipairs({{a, b}, {b, a}}) do
      local me, other = pair[1], pair[2]
      if me.disqualification then
        me.winnerResult = "DQ"
      elseif other.disqualification then
        me.winnerResult = "WINNER"
      elseif rawData.dragType == "bracketRace" then
        local meDiff  = tonumber(me.dialDiff) or 0
        local othDiff = tonumber(other.dialDiff) or 0
        if meDiff == othDiff then
          me.winnerResult = "TIE"
        elseif meDiff > 0 and othDiff > 0 then
          me.winnerResult = meDiff < othDiff and "WINNER" or ""
        else
          me.winnerResult = meDiff > othDiff and "WINNER" or "Break Out"
        end
      else
        local meTime  = tonumber(me.finalTime) or 0
        local othTime = tonumber(other.finalTime) or 0
        if meTime > othTime then
          me.winnerResult = string.format("+%0.3f", meTime - othTime)
        else
          me.winnerResult = "WINNER"
        end
      end
    end
  end

  return rawData
end

function M.createTimeslipPanelData()
  local slip = M.createTimeslipData()
  if not slip or not next(slip) then return {} end

  local ret = {}
  for _, key in ipairs({"stripInfo", "tree", "env", "racerInfos", "timerConfig", "timeslipRows", "importantTimerId"}) do
    if slip[key] ~= nil then
      ret[key] = slip[key]
    end
  end

  local grid = { labels = {}, rows = {} }
  if slip.timerConfig and #slip.timerConfig > 0 and slip.racerInfos and #slip.racerInfos > 0 then
    table.insert(grid.labels, "Racer")
    for _, t in ipairs(slip.timerConfig) do
      table.insert(grid.labels, (t.label or t.id or "") .. (t.important and " *" or ""))
    end
    for _, racerInfo in ipairs(slip.racerInfos) do
      local row = {}
      table.insert(row, { text = (racerInfo.name or ""):gsub("%.+$", "") })
      for _, entry in ipairs(racerInfo.timerEntries or {}) do
        local txt = entry.valueStr or entry.value_mph or string.format("%0.3f", entry.value or 0)
        table.insert(row, { text = txt, mono = true })
      end
      table.insert(grid.rows, row)
    end
  end

  ret.grid = grid
  return ret
end

function M.screenshotTimeslip()
  local dir = "screenshots/timeslips/" .. os.date("%Y-%m-%d_%H-%M-%S")
  if screenshot and screenshot.doScreenshot then
    screenshot.doScreenshot(nil, nil, dir, 'jpg')
    if ui_message then ui_message("Timeslip saved: " .. dir .. ".jpg", nil, nil, "save") end
  else
    log('E', logTag, "screenshot.doScreenshot not available")
  end
end

return M
