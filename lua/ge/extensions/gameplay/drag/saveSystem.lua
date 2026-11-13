-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "drag_save_system"

local DIAL_FILE = "settings/dragDialTimes.json"
local BEST_FILE = "settings/dragDialBest.json"
local HISTORY_FILE = "settings/dragDialHistory.jsonl"

local dialCache
local cacheLoaded = false
local configHashCache = {}

M.DEFAULT_TIMERS = {
  { id = "reactionTime", label = "Reaction Time", labelKey = "ui.drag.winnerBy.reactionTime", shortLabel = "R/T", type = "distanceTimer", distance = 0.178, important = false },
  { id = "time_60", label = "60 ft", labelKey = "ui.drag.winnerBy.time60", shortLabel = "60'", type = "distanceTimer", distance = 18.288, important = false },
  { id = "time_330", label = "330 ft", labelKey = "ui.drag.winnerBy.time330", shortLabel = "330'", type = "distanceTimer", distance = 100.584, important = false },
  { id = "time_1_8", label = "1/8 mile", labelKey = "ui.drag.winnerBy.time18", shortLabel = "1/8", type = "distanceTimer", distance = 201.168, important = false },
  { id = "time_1000", label = "1000 ft", labelKey = "ui.drag.winnerBy.time1000", shortLabel = "1000'", type = "distanceTimer", distance = 304.8, important = false },
  { id = "time_1_4", label = "1/4 mile", labelKey = "ui.drag.winnerBy.time14", shortLabel = "1/4", type = "distanceTimer", distance = 402.336, important = true },
  { id = "velAt_1_8", label = "Speed at 1/8 mile", labelKey = "ui.drag.winnerBy.speedAt18", type = "velocity", distance = 201.168, important = false },
  { id = "velAt_1_4", label = "Speed at 1/4 mile", labelKey = "ui.drag.winnerBy.speedAt14", type = "velocity", distance = 402.336, important = false },
}

local function createDefaultTimers()
  return deepcopy(M.DEFAULT_TIMERS), "time_1_4"
end

-- Auxiliary functions

local function getCurrentLevelDragPath()
  local levelName = getCurrentLevelIdentifier()
  if not levelName then
    log('E', logTag, 'Could not determine current level')
    return nil
  end
  return '/levels/' .. levelName .. '/dragstrips/'
end

local function normalizeTimersConfig(timersArray)
  if not timersArray or type(timersArray) ~= "table" or #timersArray == 0 then
    return nil, nil
  end
  local out = {}
  local importantId = nil
  for i, t in ipairs(timersArray) do
    if t and (t.type == "distanceTimer" or t.type == "velocity") and type(t.distance) == "number" then
      local id = t.id and tostring(t.id) ~= "" and t.id or ("timer_" .. i)
      local important = t.important == true
      if important and not importantId then
        importantId = id
      end
      table.insert(out, {
        id = id,
        label = t.label and tostring(t.label) or id,
        labelKey = t.labelKey,
        type = t.type,
        distance = t.distance,
        important = important and (importantId == id),
      })
    end
  end
  if #out == 0 then return nil, nil end
  if not importantId and #out > 0 then
    out[1].important = true
    importantId = out[1].id
  end
  return out, importantId
end

local function safeVec3(t)
  if type(t) ~= "table" or t.x == nil or t.y == nil or t.z == nil then return nil end
  return vec3(t.x, t.y, t.z)
end

local function safeQuat(t)
  if type(t) ~= "table" or t.x == nil or t.y == nil or t.z == nil or t.w == nil then return nil end
  return quat(t.x, t.y, t.z, t.w)
end

local function deserializeZone(data)
  if not data or not data.vertices or #data.vertices < 3 then return nil end
  local ZoneClass = require('/lua/ge/extensions/gameplay/sites/zone')
  local zone = ZoneClass(nil, data.name or "Zone")
  zone:onDeserialized(data)
  return zone
end

-- One lane or strip-level waypoint entry from .strip.json (same shape as lane.waypoints[type] at runtime).
local function waypointEntryFromStripJson(waypoint, logSuffix)
  local tf = waypoint.transform
  if not tf or not waypoint.type then
    log("W", logTag, "Skipping waypoint with missing transform or type" .. (logSuffix or ""))
    return nil
  end
  local pos = safeVec3(tf.position)
  local rot = safeQuat(tf.rotation)
  local scl = safeVec3(tf.scale)
  if not pos or not rot or not scl then
    log("W", logTag, 'Skipping waypoint "' .. tostring(waypoint.type) .. '" with malformed transform data' .. (logSuffix or ""))
    return nil
  end
  return {
    id = waypoint.id,
    name = waypoint.name,
    transform = {
      position = pos, rotation = rot, scale = scl,
      pos = vec3(pos.x, pos.y, pos.z), rot = rot, scl = scl,
      x = rot * vec3(scl.x, 0, 0), y = rot * vec3(0, scl.y, 0), z = rot * vec3(0, 0, scl.z),
    },
    waypoint = waypoint.waypoint,
  }
end

--- Canonical scenetree name for a lane waypoint. Uses _wp_ so types like "stage" never collide with tree lights (<stripId>_stage_<lane>).
M.laneWaypointSceneName = function(stripId, wpType, laneIndex)
  return tostring(stripId) .. "_wp_" .. tostring(wpType) .. "_" .. tostring(laneIndex)
end

-- Sync one drag-related BeamNGWaypoint at convName only (canonical scenetree name).
-- Does not create objects; waypoints must exist in the level (e.g. from strip prefab).
-- Returns true if map.reset is recommended (rename only).
local function syncDragWaypointEntry(convName, entry)
  if not convName or type(entry) ~= "table" or not entry.transform then
    return false
  end
  local obj = scenetree.findObject(convName)
  if obj and obj.getClassName and obj:getClassName() == "BeamNGWaypoint" then
    local needsRebuild = false
    if obj:getName() ~= convName then
      obj:setName(convName)
      needsRebuild = true
    end
    entry.name = convName
    local pos = obj:getPosition()
    local rot = quat(obj:getRotation())
    local scl = obj:getScale()
    entry.transform = {
      position = pos, rotation = rot, scale = scl,
      pos = vec3(pos.x, pos.y, pos.z), rot = rot, scl = scl,
      x = rot * vec3(scl.x, 0, 0), y = rot * vec3(0, scl.y, 0), z = rot * vec3(0, 0, scl.z),
    }
    return needsRebuild
  end

  if scenetree.findObject(convName) then
    log("E", logTag, "Name '" .. convName .. "' is used by a non-BeamNGWaypoint; expected a BeamNGWaypoint from level/prefab")
    return false
  end

  log("D", logTag, "Drag waypoint not in scene (place via strip prefab / level): " .. tostring(convName))
  return false
end

--- Resolves BeamNGWaypoints: lane entries use <stripId>_wp_<type>_<lane>; strip-level use <stripId>_<type>.
M.syncDragStripWaypointsWithSceneTree = function(dragData)
  if not dragData or not dragData.strip then return end
  local stripId = dragData.strip.id
  if not stripId or stripId == "" then return end

  local needsNavgraphRebuild = false

  if dragData.strip.lanes then
    for laneIndex, lane in ipairs(dragData.strip.lanes) do
      if lane.waypoints then
        for wpType, entry in pairs(lane.waypoints) do
          if type(wpType) == "string" and type(entry) == "table" and entry.transform then
            local convName = M.laneWaypointSceneName(stripId, wpType, laneIndex)
            if syncDragWaypointEntry(convName, entry) then
              needsNavgraphRebuild = true
            end
          end
        end
        if lane.waypoints.stage and lane.waypoints.endLine then
          local sp = lane.waypoints.stage.transform.position
          local ep = lane.waypoints.endLine.transform.position
          lane.stageToEndNormalized = (ep - sp):normalized()
        end
      end
    end
  end

  if dragData.strip.waypoints then
    for wpType, entry in pairs(dragData.strip.waypoints) do
      if type(wpType) == "string" and type(entry) == "table" and entry.transform then
        local convName = tostring(stripId) .. "_" .. tostring(wpType)
        if syncDragWaypointEntry(convName, entry) then
          needsNavgraphRebuild = true
        end
      end
    end
  end

  if needsNavgraphRebuild and map and map.reset then
    local ok, err = pcall(map.reset)
    if not ok then
      log("E", logTag, "map.reset() (navgraph rebuild) failed: " .. tostring(err))
    end
  end
end

local function findAutoStopNode(mapData, stagePoint, endPoint, minDist)
  local path = mapData:getPath(stagePoint, endPoint)
  local thisEndPoint, thisStagePoint = endPoint, path[#path - 1]
  if not thisStagePoint then return nil end

  local stopName
  local dist = 0
  repeat
    local thisStop
    local maxDir = 0.966  -- approx 15 degrees
    local thisStagePointPos, thisEndPointPos = mapData:getEdgePositions(thisStagePoint, thisEndPoint)
    local dirVec = thisEndPointPos - thisStagePointPos; dirVec:normalize()
    for node in pairs(mapData.graph[thisEndPoint]) do
      if node ~= thisStagePoint then
        local _, nodePos = mapData:getEdgePositions(thisEndPoint, node)
        local nodeDir = nodePos - thisEndPointPos; nodeDir:normalize()
        local dir = nodeDir:dot(dirVec)
        if dir > maxDir then
          thisStop = node
          maxDir = dir
        end
      end
    end
    if not thisStop then break end
    stopName = thisStop
    thisEndPoint, thisStagePoint = thisStop, thisEndPoint
    dist = dist + mapData.positions[thisEndPoint]:distance(mapData.positions[thisStagePoint])
  until dist >= minDist

  return stopName
end

--- Precomputes each lane's AI stopping point once, at drag data setup time, instead of walking the
-- navgraph on every AI racer's stop phase. Only needed as a fallback when the strip has no explicit
-- strip-level drag_stop waypoint; skipped entirely otherwise.
M.resolveAutoStopWaypoints = function(dragData)
  if not dragData or not dragData.strip or not dragData.strip.lanes then return end

  local wps = dragData.strip.waypoints
  if wps and wps.drag_stop and wps.drag_stop.name then return end

  local mapData = map.getGraphpath()
  if not mapData then return end

  for _, lane in ipairs(dragData.strip.lanes) do
    local stageLine = lane.waypoints and lane.waypoints.stage
    local endLine = lane.waypoints and lane.waypoints.endLine
    if stageLine and endLine then
      local ok, stopName = pcall(findAutoStopNode, mapData, stageLine.name, endLine.name, 350)
      lane.autoStopName = ok and stopName or nil
    end
  end
end

-- Functions called from outside

--- Returns path to current level's dragstrips folder, or nil.
M.getCurrentLevelDragPath = function()
  return getCurrentLevelDragPath()
end

--- Loads full drag race data from a strip file path (strip + lanes, waypoints, phases).
-- stripId: path to the strip JSON file
M.loadCompleteDragRaceData = function(stripId)
  local ok, stripData = pcall(jsonReadFile, stripId)
  if not ok or not stripData then
    log('E', logTag, 'Failed to load strip file: ' .. tostring(stripId) .. (not ok and (' — ' .. tostring(stripData)) or ''))
    return nil
  end

  local completeData = {
    strip = {
      id = stripData.id,
      name = stripData.name,
      description = stripData.description,
      endCamera = stripData.endCamera,
      lanes = {},
      waypoints = {},
      stripZone = nil
    },
    racers = {},
    phases = {
      { name = "stage", dependency = true, startedOffset = 0 },
      { name = "countdown", dependency = true, startedOffset = 0 },
      { name = "race", dependency = false, startedOffset = 0 },
      { name = "stop", dependency = false, startedOffset = 0 },
    },
    prefabs = {
      christmasTree = { isUsed = false, treeType = ".500" },
      displaySign = { isUsed = false },
      paths = { isUsed = false },
      decorations = { isUsed = false },
    },
    dragType = "headsUpRace",
    context = "freeroam",
    canBeReseted = true,
    canBeTeleported = true,
    isStarted = false,
    isCompleted = false,
  }

  if stripData.stripZone then
    completeData.strip.stripZone = deserializeZone(stripData.stripZone)
  end

  if stripData.lanes then
    for _, lane in ipairs(stripData.lanes) do
      local completeLane = {
        id = lane.id,
        shortName = lane.shortName,
        longName = lane.longName,
        color = lane.color,
        laneOrder = lane.laneOrder,
        waypoints = {},
        boundary = {},
      }

      if lane.waypoints then
        for _, waypoint in ipairs(lane.waypoints) do
          local entry = waypointEntryFromStripJson(waypoint, " in strip: " .. tostring(stripData.id or stripId))
          if entry then
            completeLane.waypoints[waypoint.type] = entry
          end
        end
      end

      if completeLane.waypoints.stage and completeLane.waypoints.endLine then
        local stagePos = completeLane.waypoints.stage.transform.position
        local endPos = completeLane.waypoints.endLine.transform.position
        completeLane.stageToEndNormalized = (endPos - stagePos):normalized()
      else
        completeLane.stageToEndNormalized = vec3(1, 0, 0)
      end

      if lane.boundary and lane.boundary.transform then
        local bPos = safeVec3(lane.boundary.transform.position)
        local bRot = safeQuat(lane.boundary.transform.rotation)
        local bScl = safeVec3(lane.boundary.transform.scale)
        if bPos and bRot and bScl then
          completeLane.boundary = {
            transform = { position = bPos, rotation = bRot, scale = bScl }
          }
        else
          log('W', logTag, 'Skipping boundary with malformed transform for lane: ' .. tostring(lane.id))
        end
      end

      if lane.zone then
        completeLane.zone = deserializeZone(lane.zone)
      end

      table.insert(completeData.strip.lanes, completeLane)
    end
  end

  if stripData.waypoints then
    for _, waypoint in ipairs(stripData.waypoints) do
      local entry = waypointEntryFromStripJson(waypoint, " (strip-level) in strip: " .. tostring(stripData.id or stripId))
      if entry then
        completeData.strip.waypoints[waypoint.type] = entry
      end
    end
  end

  completeData.timers, completeData.importantTimerId = createDefaultTimers()
  M.syncDragStripWaypointsWithSceneTree(completeData)
  return completeData
end

--- Loads drag strip data from file path. Supports modular (stripId + dragSettings) and legacy format.
-- filepath: path to JSON file
M.loadDragStripData = function(filepath)
  if not filepath then
    log('E', logTag, 'No filepath provided for loading drag strip data')
    return nil
  end

  local ok, data = pcall(jsonReadFile, filepath)
  if not ok or not data then
    log('E', logTag, 'Failed to read drag strip data file: ' .. tostring(filepath) .. (not ok and (' — ' .. tostring(data)) or ''))
    return nil
  end

  if data.stripId then
    local stripData = M.loadCompleteDragRaceData(data.stripId)
    if stripData then
      stripData.id = data.id
      stripData.dragType = data.dragType or stripData.dragType
      stripData.context = data.context or stripData.context
      stripData.phases = data.phases or stripData.phases
      stripData.prefabs = data.prefabs or stripData.prefabs
      stripData.canBeReseted = data.canBeReseted ~= nil and data.canBeReseted or stripData.canBeReseted
      stripData.canBeTeleported = data.canBeTeleported ~= nil and data.canBeTeleported or stripData.canBeTeleported
      local normTimers, importantId = normalizeTimersConfig(data.timers)
      if normTimers and #normTimers > 0 then
        stripData.timers = normTimers
        stripData.importantTimerId = importantId
      else
        stripData.timers, stripData.importantTimerId = createDefaultTimers()
      end
      return stripData
    else
      log('E', logTag, 'Failed to load complete drag race data')
    end
  end

  return M.convertLegacyData(data)
end

--- Converts legacy drag strip format to current strip/lanes/waypoints structure.
-- legacyData: table in old format
M.convertLegacyData = function(legacyData)
  if not legacyData then
    log('E', logTag, 'No legacy data to convert')
    return nil
  end

  local convertedData = {
    strip = {
      id = legacyData.stripInfo and legacyData.stripInfo.id or "legacy_strip",
      name = legacyData.stripInfo and legacyData.stripInfo.stripName or "Legacy Strip",
      description = "Converted from legacy format",
      lanes = {},
      waypoints = {},
    },
    dragType = legacyData.dragType or "",
    context = legacyData.context or "",
    phases = legacyData.phases or {},
    prefabs = legacyData.prefabs or {},
    canBeReseted = legacyData.canBeReseted or false,
    canBeTeleported = legacyData.canBeTeleported or false,
    stripInfo = legacyData.stripInfo or {},
  }

  if legacyData.strip and legacyData.strip.lanes then
    for i, lane in ipairs(legacyData.strip.lanes) do
      local convertedLane = {
        id = "legacy_lane_" .. i,
        shortName = lane.shortName or ("Lane " .. i),
        longName = lane.longName or ("Lane " .. i),
        color = lane.color or "blue",
        laneOrder = lane.laneOrder or i,
        waypoints = {},
        boundary = lane.boundary or {},
      }
      if lane.waypoints then
        for waypointType, waypoint in pairs(lane.waypoints) do
          convertedLane.waypoints[waypointType] = {
            name = waypoint.name or waypointType,
            transform = waypoint.transform or { pos = vec3(0, 0, 0), rot = quat(0, 0, 0, 1), scl = vec3(1, 1, 1) },
            waypoint = waypoint.waypoint or { speed = 5, mode = "limit" },
          }
        end
      end
      table.insert(convertedData.strip.lanes, convertedLane)
    end
  end

  convertedData.timers, convertedData.importantTimerId = createDefaultTimers()
  M.syncDragStripWaypointsWithSceneTree(convertedData)
  return convertedData
end

local function slipKey(hash, slip)
  local info = slip and slip.stripInfo or nil
  local stamp = info and (info.dateTime or info.timestamp) or ""
  local finals = ""
  if slip and slip.racerInfos then
    for i = 1, #slip.racerInfos do
      finals = finals .. tostring(slip.racerInfos[i].finalTime or "") .. ","
    end
  end
  return tostring(hash) .. "\0" .. tostring(stamp) .. "\0" .. tostring(slip and slip.stripId or "") .. "\0" .. finals
end

local function dialHasHistory(cache)
  for _, data in pairs(cache) do
    if type(data) == "table" and type(data.history) == "table" and data.history[1] then
      return true
    end
  end
  return false
end

local function bestTable(cache)
  local out = {}
  for hash, data in pairs(cache) do
    local row = {}
    for k, v in pairs(data) do
      if k ~= "history" then
        row[k] = v
      end
    end
    out[hash] = row
  end
  return out
end

local function rememberSlip(hash, slip)
  local bucket = dialCache[hash]
  if not bucket then
    bucket = {}
    dialCache[hash] = bucket
  end
  if not bucket.history then bucket.history = {} end
  bucket.history[#bucket.history + 1] = slip
end

local function collectHistoryRows(cache)
  local rows = {}
  for hash, data in pairs(cache) do
    if type(data.history) == "table" then
      for i = 1, #data.history do
        rows[#rows + 1] = { configHash = hash, slip = data.history[i] }
      end
    end
  end
  return rows
end

local function readHistoryRows(path)
  local rows = {}
  local f = io.open(path, "r")
  if not f then return rows end
  for line in f:lines() do
    if line ~= "" then
      local row = jsonDecode(line, path)
      if type(row) == "table" and row.configHash and type(row.slip) == "table" then
        rows[#rows + 1] = row
      end
    end
  end
  f:close()
  return rows
end

local function writeHistoryRows(path, rows)
  local f = io.open(path, "w")
  if not f then return false end
  for i = 1, #rows do
    f:write(jsonEncode(rows[i]))
    f:write("\n")
  end
  f:close()
  return true
end

-- One compact line per run. Rewriting the whole history book is what froze the finish frame.
local function replaceHistoryFile(rows)
  local tmp = HISTORY_FILE .. ".tmp"
  if not writeHistoryRows(tmp, rows) then
    log('E', logTag, 'Unable to write drag history')
    return false
  end
  if not FS:fileExists(HISTORY_FILE) then
    if FS:renameFile(tmp, HISTORY_FILE) == 0 then
      return true
    end
    log('E', logTag, 'Failed to replace drag history file')
    return false
  end
  local bak = HISTORY_FILE .. ".bak"
  if FS:fileExists(bak) then
    FS:removeFile(bak)
  end
  if FS:renameFile(HISTORY_FILE, bak) ~= 0 then
    log('E', logTag, 'Failed to move old drag history file')
    return false
  end
  if FS:renameFile(tmp, HISTORY_FILE) ~= 0 then
    FS:renameFile(bak, HISTORY_FILE)
    log('E', logTag, 'Failed to replace drag history file')
    return false
  end
  FS:removeFile(bak)
  return true
end

local function appendHistoryRow(row)
  local f = io.open(HISTORY_FILE, "a")
  if not f then
    log('E', logTag, 'Unable to append drag history')
    return false
  end
  f:write(jsonEncode(row))
  f:write("\n")
  f:close()
  return true
end

local function mergeBestOverlay()
  local bestOverlay = jsonReadFile(BEST_FILE)
  if not bestOverlay then return end
  for hash, data in pairs(bestOverlay) do
    if type(data) == "table" then
      local bucket = dialCache[hash]
      if not bucket then
        bucket = {}
        dialCache[hash] = bucket
      end
      for k, v in pairs(data) do
        if k ~= "history" then
          bucket[k] = v
        end
      end
    end
  end
end

-- Loads dial times once per session. Legacy history is moved out of the pretty JSON file so later finishes do not rewrite it.
function M.ensureDialCache()
  if cacheLoaded then return dialCache end
  cacheLoaded = true
  dialCache = jsonReadFile(DIAL_FILE) or {}

  local diskRows = readHistoryRows(HISTORY_FILE)
  if dialHasHistory(dialCache) then
    local seen = {}
    local rows = collectHistoryRows(dialCache)
    for i = 1, #rows do
      seen[slipKey(rows[i].configHash, rows[i].slip)] = true
    end
    for i = 1, #diskRows do
      local row = diskRows[i]
      local key = slipKey(row.configHash, row.slip)
      if not seen[key] then
        seen[key] = true
        rememberSlip(row.configHash, row.slip)
        rows[#rows + 1] = row
      end
    end
    if replaceHistoryFile(rows) then
      jsonWriteFile(DIAL_FILE, bestTable(dialCache), false, nil, true)
    end
  else
    for i = 1, #diskRows do
      rememberSlip(diskRows[i].configHash, diskRows[i].slip)
    end
  end

  mergeBestOverlay()
  return dialCache
end

--- Saves dial times and optional timeslip history for playable racers.
-- dragData: current drag data, timeslip: optional timeslip table to save to history
M.saveDialTimes = function(dragData, timeslip)
  if not dragData or not dragData.racers then
    log('E', logTag, 'No drag data or racers to save dial times')
    return
  end

  local cache = M.ensureDialCache()
  local importantId = dragData.importantTimerId or "time_1_4"
  local bestChanged = false

  for vehId, racer in pairs(dragData.racers) do
    local importantTimer = racer.timers and racer.timers[importantId]
    if importantTimer and racer.isPlayable then
      local timesKey = M.generateHashFromFile(vehId)
      local currentTime = importantTimer.value or 10
      local bucket = cache[timesKey]
      if not bucket then
        bucket = { time_1_4 = currentTime }
        cache[timesKey] = bucket
        bestChanged = true
      end
      local prevBest = bucket[importantId] or bucket.time_1_4 or 10
      if currentTime < prevBest then
        bucket[importantId] = currentTime
        bucket.time_1_4 = currentTime
        bestChanged = true
      end
      if timeslip then
        local historyEntry = deepcopy(timeslip)
        historyEntry.stripId = dragData.strip and dragData.strip.id or "unknown"
        if timeslip.stripInfo and timeslip.stripInfo.tree then
          historyEntry.tree = timeslip.stripInfo.tree
        end
        if historyEntry.racerInfos and dragData.racers then
          for _, racerInfo in ipairs(historyEntry.racerInfos) do
            for rVehId, rRacer in pairs(dragData.racers) do
              if rRacer.lane == racerInfo.laneNum then
                racerInfo.configHash = M.generateHashFromFile(rVehId)
                break
              end
            end
          end
        end
        if not bucket.history then bucket.history = {} end
        bucket.history[#bucket.history + 1] = historyEntry
        appendHistoryRow({ configHash = timesKey, slip = historyEntry })
      end
    end
  end

  if bestChanged then
    jsonWriteFile(BEST_FILE, bestTable(cache), false)
  end
end

--- Returns dial times keyed by config hash.
M.getDialTimes = function()
  local dialTimes = M.ensureDialCache()
  local result = {}
  for configHash, data in pairs(dialTimes) do
    result[configHash] = {}
    result[configHash].time_1_4 = data.time_1_4 or 10
    for k, v in pairs(data) do
      if k ~= "history" and k ~= "time_1_4" then
        result[configHash][k] = v
      end
    end
  end
  return result
end

--- Generates a stable hash from the vehicle's config file for dial/history keys.
-- vehicleId: vehicle ID (defaults to player vehicle)
M.generateHashFromFile = function(vehicleId)
  if not vehicleId then
    vehicleId = be:getPlayerVehicleID(0)
  end
  local vehicleDetails = core_vehicles.getVehicleDetails(vehicleId)
  if not vehicleDetails or not vehicleDetails.current then
    log('W', logTag, 'Could not get vehicle details for ID: ' .. tostring(vehicleId))
    return "vehicle_" .. tostring(vehicleId)
  end
  local configFile = vehicleDetails.current.pc_file
  if not configFile or configFile == "" then
    return "vehicle_" .. tostring(vehicleId)
  end
  if not string.find(configFile, "^/") then
    configFile = "/" .. configFile
  end
  local cacheKey = tostring(vehicleId) .. "\0" .. configFile
  local cached = configHashCache[cacheKey]
  if cached then return cached end
  local hash = "vehicle_" .. tostring(vehicleId)
  if FS:fileExists(configFile) then
    local fileHash = FS:hashFile(configFile)
    if fileHash and fileHash ~= "" then hash = fileHash end
  end
  configHashCache[cacheKey] = hash
  return hash
end

--- Returns current career save path, or empty string.
M.getCurrentSavePath = function()
  return career_career and career_career.getCurrentSavePath() or ""
end

--- Copies dial times to a save directory.
-- dir: target directory path
M.saveDialFile = function(dir)
  if not dir then return false end
  local dialTimes = M.ensureDialCache()
  local savePath = dir .. "/dragDialTimes.json"
  local success = jsonWriteFile(savePath, dialTimes, false)
  if not success then
    log('E', logTag, 'Failed to save dial file to: ' .. savePath)
  end
  return success
end

--- Returns history entries from dial times. Optionally filters by drag settings id / strip file id on this level.
M.getHistory = function(id)
  local dialTimes = M.ensureDialCache()
  local allHistory = {}
  for _, data in pairs(dialTimes) do
    if data.history then
      for _, entry in ipairs(data.history) do
        table.insert(allHistory, entry)
      end
    end
  end

  if not id then
    return { history = allHistory }
  end

  local levelPath = getCurrentLevelDragPath()
  local stripIdsToMatch = {}
  local seen = {}
  local function addStripId(sid)
    if sid and sid ~= "" and not seen[sid] then
      seen[sid] = true
      table.insert(stripIdsToMatch, sid)
    end
  end

  if levelPath then
    local settingsFiles = FS:findFiles(levelPath, "*.dragSettings.json", -1, true, false)
    for _, file in ipairs(settingsFiles) do
      local data = jsonReadFile(file)
      if data then
        local _, fn, ext = path.split(file, true)
        local base = string.sub(fn, 1, #fn - #ext - 1)
        local settingsId = data.id or base
        if settingsId == id or base == id then
          addStripId(settingsId)
          addStripId(base)
          if data.stripId then
            local stripData = jsonReadFile(data.stripId)
            if not stripData then
              stripData = jsonReadFile(data.stripId:gsub("/dragRaces/", "/dragstrips/"))
            end
            if not stripData then
              stripData = jsonReadFile(data.stripId:gsub("/dragstrips/", "/dragRaces/"))
            end
            if stripData and stripData.id then
              addStripId(stripData.id)
            end
          end
        end
      end
    end
  end

  if #stripIdsToMatch == 0 then
    for _, entry in ipairs(allHistory) do
      if entry.stripId and string.find(entry.stripId, "^" .. id) then
        addStripId(entry.stripId)
      end
    end
  end

  if #stripIdsToMatch == 0 then
    addStripId(id)
  end

  local filteredHistory = {}
  for _, entry in ipairs(allHistory) do
    if entry.stripId then
      for _, stripId in ipairs(stripIdsToMatch) do
        if entry.stripId == stripId then
          table.insert(filteredHistory, entry)
          break
        end
      end
    end
  end

  return { history = filteredHistory }
end

--- Returns up to `count` saved timeslips across all strips, newest first.
M.getRecentHistory = function(count)
  local history = M.getHistory().history
  table.sort(history, function(a, b)
    return (a.stripInfo and a.stripInfo.timestamp or 0) > (b.stripInfo and b.stripInfo.timestamp or 0)
  end)
  local recent = {}
  for i = 1, math.min(count, #history) do recent[i] = history[i] end
  return recent
end

--- Hook: saves dial file when save slot changes.
-- currentSavePath: path to current save directory
M.onSaveCurrentProfile = function(currentSavePath)
  if currentSavePath then M.saveDialFile(currentSavePath) end
end

M.onCareerActive = function() end

--- Returns all strip data from current level.
M.getAllStrips = function()
  local strips = {}
  local levelPath = getCurrentLevelDragPath()
  if levelPath then
    local stripFiles = FS:findFiles(levelPath, "*.strip.json", -1, true, false)
    for _, file in ipairs(stripFiles) do
      local strip = jsonReadFile(file)
      if strip then
        strip._filePath = file
        table.insert(strips, strip)
      end
    end
  end
  return strips
end

--- Returns all lanes from all strips in current level.
M.getAllLanes = function()
  local lanes = {}
  for _, strip in ipairs(M.getAllStrips()) do
    if strip.lanes then
      for _, lane in ipairs(strip.lanes) do
        lane._stripId = strip.id
        lane._stripName = strip.name
        table.insert(lanes, lane)
      end
    end
  end
  return lanes
end

M.saveStrip = function(strip, filePath)
  if strip and strip.id and strip.lanes then
    for laneIndex, lane in ipairs(strip.lanes) do
      if lane.waypoints then
        for _, wp in ipairs(lane.waypoints) do
          if wp.type then
            wp.name = M.laneWaypointSceneName(strip.id, wp.type, laneIndex)
          end
        end
      end
    end
  end
  return jsonWriteFile(filePath, strip, true)
end
M.saveLane = function(lane, filePath) return jsonWriteFile(filePath, lane, true) end

--- Spawns prefabs from data.prefabs into the scene.
-- data: drag data with prefabs table
M.loadPrefabs = function(data)
  if not data or not data.prefabs then return end
  local prefabDefs = {
    { key = "christmasTree", nameFn = function(p) return (({[".400"] = "Pro Tree", [".500"] = "Sportsman Tree"})[p.treeType]) or "Christmas Tree" end },
    { key = "displaySign", nameFn = function() return "Display Sign" end },
    { key = "decorations", nameFn = function() return "Decorations" end },
    { key = "paths", nameFn = function() return "Paths" end },
  }
  for _, def in ipairs(prefabDefs) do
    local p = data.prefabs[def.key]
    if p and p.isUsed and p.path then
      local prefabId = spawnPrefab(def.nameFn(p), p.path, "0 0 0", "0 0 1 0", "1 1 1", false)
      if prefabId then p.prefabId = prefabId:getID() end
    end
  end
end

--- Removes prefabs from the scene and clears prefabId on data.
-- data: drag data with prefabs table
M.unloadPrefabs = function(data)
  if not data or not data.prefabs then return end
  for _, key in ipairs({"christmasTree", "displaySign", "decorations", "paths"}) do
    local p = data.prefabs[key]
    if p and p.isUsed and p.prefabId then
      local prefabObj = scenetree.findObjectById(p.prefabId)
      if prefabObj then prefabObj:delete() end
      p.prefabId = nil
    end
  end
end

return M
