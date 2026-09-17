-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared utility for applying mission variables to flowgraph managers
local M = {}

-- Helper function to normalize paths for comparison
local function normalizePath(p)
  p = string.gsub(p, "\\", "/")
  p = string.gsub(p, "^/+", "")
  return string.lower(p)
end

-- Check if a manager's path matches a selected mission
-- Returns: matchType ("exact", "missionTypeMain", "sameMissionType", "differentMissionType", "noMission"), normalizedMgrPath, normalizedMissionPath
function M.checkMissionMatch(mgr, selectedMission)
  if not mgr then
    return "noMission", "", ""
  end

  if not selectedMission then
    return "noMission", "", ""
  end

  -- Build manager path
  local mgrPath = ""
  if mgr.savedDir and mgr.savedFilename then
    if string.endswith(mgr.savedFilename, ".flow.json") then
      mgrPath = mgr.savedDir .. mgr.savedFilename
    else
      mgrPath = mgr.savedDir .. mgr.savedFilename .. ".flow.json"
    end
  end

  -- Get mission flowgraph path
  local missionFgPath = selectedMission.fgPath or ""
  if not missionFgPath or missionFgPath == "" then
    -- Try to get from the mission instance
    local missionInstance = gameplay_missions_missions and gameplay_missions_missions.getMissionById(selectedMission.id)
    if missionInstance and missionInstance.fgPath then
      missionFgPath = missionInstance.fgPath
    end
  end

  -- Normalize paths for comparison
  local normalizedMgrPath = normalizePath(mgrPath)
  local normalizedMissionPath = normalizePath(missionFgPath)

  -- Check match type
  local exactMatch = (normalizedMgrPath == normalizedMissionPath)
  if exactMatch then
    return "exact", normalizedMgrPath, normalizedMissionPath
  end

  -- Check if this is the mission type's main flowgraph (where variables are defined)
  if selectedMission.missionType then
    local missionTypeMainPath = "gameplay/missiontypes/" .. string.lower(selectedMission.missionType) .. "/" .. string.lower(selectedMission.missionType) .. ".flow.json"
    if normalizedMgrPath == missionTypeMainPath then
      return "missionTypeMain", normalizedMgrPath, normalizedMissionPath
    end
  end

  -- Check if same mission type folder (but different file)
  if selectedMission.missionType then
    local missionTypePath = "gameplay/missiontypes/" .. string.lower(selectedMission.missionType) .. "/"
    if string.find(normalizedMgrPath, missionTypePath, 1, true) then
      return "sameMissionType", normalizedMgrPath, normalizedMissionPath
    end
  end

  -- Check if it's a different mission type
  return "differentMissionType", normalizedMgrPath, normalizedMissionPath
end

-- Helper function to apply mission variables from mission editor to a flowgraph manager
function M.applyMissionVariablesToManager(mgr, logTag)
  logTag = logTag or "missionVariableHelper"

  log("D", logTag, "Applying mission variables to flowgraph manager")

  if not editor_missionEditor then
    log("D", logTag, "Mission Editor not loaded")
    return false
  end

  local selectedMission = editor_missionEditor.getSelectedMissionId()
  if not selectedMission then
    log("D", logTag, "No mission selected in Mission Editor")
    return false
  end

  log("D", logTag, "Selected mission: " .. tostring(selectedMission.id))

  -- Check if paths match
  local matchType, normalizedMgrPath, normalizedMissionPath = M.checkMissionMatch(mgr, selectedMission)

  log("I", logTag, "Comparing paths:")
  log("I", logTag, "  Manager path: " .. normalizedMgrPath)
  log("I", logTag, "  Mission path: " .. normalizedMissionPath)

  -- Log information about path matching
  if matchType == "exact" then
    log("I", logTag, "Exact match - this is the mission instance's custom flowgraph")
  elseif matchType == "missionTypeMain" then
    log("I", logTag, "Mission type main flowgraph - this is where variables are defined for mission type '" .. selectedMission.missionType .. "'")
  elseif matchType == "sameMissionType" then
    log("W", logTag, "Paths don't match exactly, but both are in mission type '" .. selectedMission.missionType .. "' - applying variables anyway")
  elseif matchType == "differentMissionType" then
    log("W", logTag, "Different mission type - this flowgraph may not belong to the selected mission, but applying variables anyway")
  elseif matchType == "noMission" then
    log("D", logTag, "No mission selected - cannot apply variables")
  end

  -- Get the mission type data (fgVariables)
  local missionTypeData = selectedMission.missionTypeData or {}
  if not next(missionTypeData) then
    log("W", logTag, "Mission has no missionTypeData variables")
    return false
  end

  log("D", logTag, string.format("Found %s mission variables to apply from Mission to Flowgraph", tableSize(missionTypeData)))

  -- Apply variables to the flowgraph
  local applied = 0
  local notFound = 0
  for name, value in pairs(missionTypeData) do
    if mgr.variables:variableExists(name) then
      if mgr.variables:changeBase(name, value) then
        applied = applied + 1
        log("D", logTag, string.format("  [+] %s -> set to %s", name, dumps(value, 2)))
      else
        log("W", logTag, string.format("  [!] %s -> failed to set", name))
      end
    else
      notFound = notFound + 1
      log("D", logTag, string.format("  [x] %s -> skipped since it doesn't exist in flowgraph", name))
    end
  end

  -- Inject player vehicle ID into specific flowgraph variables
  local vehicleIdVarNames = {"playerID", "playerId", "vehID", "vehId"}
  local injected = 0
  for _, varName in ipairs(vehicleIdVarNames) do
    if mgr.variables:variableExists(varName) then
      local vehicleId = getPlayerVehicle(0):getID()
      if mgr.variables:changeBase(varName, vehicleId) then
        injected = injected + 1
        log("D", logTag, string.format("  [#] %s -> injected player vehicle ID = %s", varName, tostring(vehicleId)))
      end
    end
  end

  if applied > 0 or injected > 0 then
    log("D", logTag, string.format("Successfully applied %s variables from mission: %s", applied, selectedMission.id))
    if injected > 0 then
      log("D", logTag, string.format("  (+ %s vehicle ID variables injected)", injected))
    end
    if notFound > 0 then
      log("D", logTag, string.format("  (%s variables skipped - not defined in flowgraph)", notFound))
    end
    return true
  else
    log("D", logTag, string.format("No variables were applied (found %s undefined variables)", notFound))
    return false
  end
end

return M

