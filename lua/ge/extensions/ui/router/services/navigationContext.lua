-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function bool(value)
  return value and true or false
end

local function safeCall(fn, fallback, ...)
  if type(fn) ~= "function" then return fallback end
  local ok, result = pcall(fn, ...)
  if not ok then return fallback end
  if result == nil then return fallback end
  return result
end

local function getCurrentMode(context)
  if context.isMultiplayerActive then return "multiplayer" end
  if context.isMissionActive then return "mission" end
  if context.isScenarioActive then return "scenario" end
  if context.isGarageActive then return "garage" end
  if context.isCareerActive then return "career" end
  if context.isFreeroamTutorialActive then return "freeroamTutorial" end
  if context.isMultiseatGamemodeActive then return "multiseatGamemode" end

  return "freeroam"
end

function M.getContext()
  local isMultiseatActive = bool(core_multiseat and core_multiseat.isMultiseatActive and safeCall(core_multiseat.isMultiseatActive, false))
  local isMultiseatGamemodeActive = bool(gameplay_multiseat_gamemodeManager and gameplay_multiseat_gamemodeManager.isActive and safeCall(gameplay_multiseat_gamemodeManager.isActive, false))
  local isMultiseatFreeroamActive = bool(ui_multiseat_freeroam and ui_multiseat_freeroam.isActive and safeCall(ui_multiseat_freeroam.isActive, false))
  local multiseatPlayers = safeCall(core_multiseat and core_multiseat.getPlayers, {})
  local isMultiplePlayersActive = type(multiseatPlayers) == "table" and #multiseatPlayers > 1
  local isFirstDriveActive = bool(gameplay_discover_firstDrive_experience
    and gameplay_discover_firstDrive_experience.isActive
    and safeCall(gameplay_discover_firstDrive_experience.isActive, false))
  local isFirstDriveGuided = bool(gameplay_discover_firstDrive_experience
    and gameplay_discover_firstDrive_experience.isGuidedDriveActive
    and safeCall(gameplay_discover_firstDrive_experience.isGuidedDriveActive, false))

  local context = {
    isCareerActive = bool(career_career and career_career.isActive and safeCall(career_career.isActive, false)),
    isGarageActive = bool(gameplay_garageMode and gameplay_garageMode.isActive and safeCall(gameplay_garageMode.isActive, false)),
    isMissionActive = bool(gameplay_missions_missionManager and gameplay_missions_missionManager.getForegroundMissionId and safeCall(gameplay_missions_missionManager.getForegroundMissionId, nil) ~= nil),
    isScenarioActive = bool(scenario_scenarios and scenario_scenarios.getScenario and safeCall(scenario_scenarios.getScenario, nil) ~= nil),
    isMultiplayerActive = bool(multiplayer_sessionManager and multiplayer_sessionManager.getCurrentSession and safeCall(multiplayer_sessionManager.getCurrentSession, nil) ~= nil),
    foregroundMissionId = safeCall(gameplay_missions_missionManager and gameplay_missions_missionManager.getForegroundMissionId, nil),
    isBigMapBlocked = bool(core_input_actionFilter and core_input_actionFilter.isActionBlocked and safeCall(core_input_actionFilter.isActionBlocked, false, "toggleBigMap")),
    isFreeroamTutorialActive = gameplay_discover_freeroamTutorial_tutorial ~= nil,
    isFirstDriveActive = isFirstDriveActive,
    isFirstDriveGuided = isFirstDriveGuided,
    isMultiseatGamemodeActive = isMultiseatGamemodeActive,
    isMultiseatActive = isMultiseatActive or isMultiseatFreeroamActive or isMultiplePlayersActive,
  }

  context.isBigMapAllowed = not context.isBigMapBlocked
  context.mode = getCurrentMode(context)
  return context
end

local function routeSummary(route)
  if not route then
    return nil
  end

  return {
    name = route.name,
    params = route.params or {},
    -- query = route.query or {},
    meta = route.meta or {},
  }
end

function M.buildNavigationContext(toRoute, fromRoute, kind, extras)
  local context = M.getContext()
  context.kind = kind
  context.extras = extras or {}
  context.toRoute = routeSummary(toRoute)
  context.fromRoute = routeSummary(fromRoute)
  return context
end

return M
