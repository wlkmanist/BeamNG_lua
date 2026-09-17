-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.qualityLevels = {
  Lowest = {
  },
  Low = {
  },
  High = {
  },
  Ultra = {
  }
}

M.qualityLevels.Lowest["$pref::lightManager"] = "Basic Lighting"
M.qualityLevels.Lowest["$pref::Shadows::filterMode"] = "None"
M.qualityLevels.Lowest["$pref::Video::disablePixSpecular"] = false
M.qualityLevels.Lowest["$pref::Video::disableNormalmapping"] = false
M.qualityLevels.Lowest["$pref::Video::disableParallaxMapping"] = true
M.qualityLevels.Lowest["$pref::Water::disableTrueReflections"] = true
M.qualityLevels.Lowest["$pref::Video::ShaderQualityGroup"] = "Low"

M.qualityLevels.Low["$pref::lightManager"] = "Advanced Lighting"
M.qualityLevels.Low["$pref::Shadows::filterMode"] = "SoftShadow"
M.qualityLevels.Low["$pref::Video::disablePixSpecular"] = false
M.qualityLevels.Low["$pref::Video::disableNormalmapping"] = false
M.qualityLevels.Low["$pref::Video::disableParallaxMapping"] = false
M.qualityLevels.Low["$pref::Water::disableTrueReflections"] = false
M.qualityLevels.Low["$pref::Video::ShaderQualityGroup"] = "High"

M.qualityLevels.High["$pref::lightManager"] = "Advanced Lighting 1.5"
M.qualityLevels.High["$pref::Shadows::filterMode"] = "SoftShadow"
M.qualityLevels.High["$pref::Video::disablePixSpecular"] = false
M.qualityLevels.High["$pref::Video::disableNormalmapping"] = false
M.qualityLevels.High["$pref::Video::disableParallaxMapping"] = false
M.qualityLevels.High["$pref::Water::disableTrueReflections"] = false
M.qualityLevels.High["$pref::Video::ShaderQualityGroup"] = "High"

M.qualityLevels.Ultra["$pref::lightManager"] = "Advanced Lighting 1.5"
M.qualityLevels.Ultra["$pref::Shadows::filterMode"] = "SoftShadow"
M.qualityLevels.Ultra["$pref::Video::disablePixSpecular"] = false
M.qualityLevels.Ultra["$pref::Video::disableNormalmapping"] = false
M.qualityLevels.Ultra["$pref::Video::disableParallaxMapping"] = false
M.qualityLevels.Ultra["$pref::Water::disableTrueReflections"] = false
M.qualityLevels.Ultra["$pref::Video::ShaderQualityGroup"] = "High"

M.onApply = function()
  local lightManager = VariableRegistry.get("$pref::lightManager")
  if getActiveLightManager and getActiveLightManager() == lightManager then
    return
  end
  setLightManager(lightManager)
end

return M