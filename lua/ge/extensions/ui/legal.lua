-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

local onlineFeaturesKey = "onlineFeatures"
local telemetryKey = "telemetry"
local legalModuleName = "legal"

local function isLegalRoute(route)
  if type(route) ~= "table" or type(route.name) ~= "string" then
    return false
  end
  local tokens = string.split(route.name, "[^%.]+")
  return tokens[1] == legalModuleName
end

local function isOnlineConsentSet()
  local onlineFeatures = core_settings_settings.getValue(onlineFeaturesKey)
  -- dump("onlineFeatures: " .. onlineFeatures)
  local telemetry = core_settings_settings.getValue(telemetryKey)
  -- dump("telemetry: " .. telemetry)
  local isConsentSet = telemetry ~= "ask" and onlineFeatures ~= "ask"

  -- set online features as accepted for simplemenu, because the user has already accepted TOS
  if Engine.UI.isSimpleMenu() and not isConsentSet then
    core_settings_settings.setState({ onlineFeatures = "enable", telemetry = "enable" })
    core_settings_settings.requestSave()
    isConsentSet = true
  end

  return isConsentSet
end

M.canLeaveOnlineConsent = function(route)
  -- Allow movement within the legal subtree so the consent wizard can complete.
  if isLegalRoute(route) then
    return true
  end

  return isOnlineConsentSet()
end

M.isOnlineConsentSet = isOnlineConsentSet

return M