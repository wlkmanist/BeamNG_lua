-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local defaultDOI = 100 -- The default domain of influence, in meters.
local defaultMargin = 5.0 -- The default margin value, in meters.
local defaultFalloff = 1.5 -- The default falloff value, in meters.
local defaultRoughness = 0.4 -- The default noise roughness value, in [0, 1].
local defaultScale = 0.5 -- The default noise scale value, in [0, 1].

local DOISliderMin, DOISliderMax = 1, 500 -- The minimum and maximum values of the DOI (domain of influence) slider, in meters.
local MarginSliderMin, MarginSliderMax = 0.0, 20.0 -- The minimum and maximum values of the margin slider, in meters.
local FalloffSliderMin, FalloffSliderMax = 1.0, 5.0 -- The minimum and maximum values of the falloff slider, in meters.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local terraCore = require('editor/terraform/terraform')
local sourceFetcher = require('editor/terraform/fetchSources')
local poly = require('editor/toolUtilities/polygon')


-- Getters for the tool properties.
local function getDOI() return editor.getPreference("terraformTool.general.domainOfInfluence") or defaultDOI end
local function getMargin() return editor.getPreference("terraformTool.general.margin") or defaultMargin end
local function getFalloff() return editor.getPreference("terraformTool.general.falloff") or defaultFalloff end
local function getRoughness() return editor.getPreference("terraformTool.general.roughness") or defaultRoughness end
local function getScale() return editor.getPreference("terraformTool.general.scale") or defaultScale end

-- Setters for the tool properties.
local function setDOI(value) editor.setPreference("terraformTool.general.domainOfInfluence", value) end
local function setMargin(value) editor.setPreference("terraformTool.general.margin", value) end
local function setFalloff(value) editor.setPreference("terraformTool.general.falloff", value) end
local function setRoughness(value) editor.setPreference("terraformTool.general.roughness", value) end
local function setScale(value) editor.setPreference("terraformTool.general.scale", value) end

-- Returns the current polygon.
local function getPolygon() return poly.getPolygon() end

-- Checks if a valid polygon exists.
local function isPolygonExist() return poly.isPolygonValid() end

-- Clears the current polygon.
local function clearPolygon() poly.clearPolygon() end

-- Terraform to the polygon.
local function terraformPolygon(polygon)
  local sources = sourceFetcher.getAllSourcesInPolygon(polygon) -- Get all the sources within the polygon, in a standardised format.
  terraCore.terraformToSources(getDOI(), getMargin(), getFalloff(), getRoughness(), getScale(), sources) -- Terraform the polygon wrt the sources.
end

-- Handles the terraforming polygon drawing.
local function handleTerraformingPolygon() poly.handleUserPolygon(terraformPolygon) end

-- Terraform to the selection.
local function terraformSelection()
  local sources = sourceFetcher.getAllSourcesInSelection() -- Get all the supported selection objects, in a standardised format.
  terraCore.terraformToSources(getDOI(), getMargin(), getFalloff(), getRoughness(), getScale(), sources) -- Terraform the polygon wrt the sources.
end

-- Register preferences.
local function onEditorRegisterPreferences(prefs)
  prefs:registerCategory("terraformTool")
  prefs:registerSubCategory("terraformTool", "general", nil, {
    { domainOfInfluence = { "int", defaultDOI, "Terraforming domain of influence", "Domain of Influence", DOISliderMin, DOISliderMax } },
    { margin = { "float", defaultMargin, "Terraforming lateral margin", "Margin", MarginSliderMin, MarginSliderMax } },
    { falloff = { "float", defaultFalloff, "Terraforming falloff", "Falloff", FalloffSliderMin, FalloffSliderMax } },
    { roughness = { "float", defaultRoughness, "Terraforming roughness", "Roughness", 0, 1 } },
    { scale = { "float", defaultScale, "Terraforming scale", "Scale", 0, 1 } },
  })
end


-- Public interface.
M.getDOI =                                              getDOI
M.getMargin =                                           getMargin
M.getFalloff =                                          getFalloff
M.getRoughness =                                        getRoughness
M.getScale =                                            getScale
M.setDOI =                                              setDOI
M.setMargin =                                           setMargin
M.setFalloff =                                          setFalloff
M.setRoughness =                                        setRoughness
M.setScale =                                            setScale

M.getPolygon =                                          getPolygon
M.isPolygonExist =                                      isPolygonExist
M.clearPolygon =                                        clearPolygon
M.handleTerraformingPolygon =                           handleTerraformingPolygon
M.terraformPolygon =                                    terraformPolygon
M.terraformSelection =                                  terraformSelection

M.onEditorRegisterPreferences =                         onEditorRegisterPreferences

return M