-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {"editor_api_dynamicDecals", "ui_liveries_camera", "ui_liveries_fill", "ui_liveries_saves"}

local dynamicTexturesSkin = "dynamicTextures"

local skinBeforeSetup = nil
local isRunning = false
local api = extensions.editor_api_dynamicDecals

local function getCurrentSkin()
  local vehicleObj = getPlayerVehicle(0)
  if not vehicleObj then return nil end

  local data = core_vehicle_manager.getPlayerVehicleData()
  local partsTree = data and data.config and data.config.partsTree
  local paintDesignSlot = partsTree and partsTree.children and partsTree.children["paint_design"]
  local partName = paintDesignSlot and paintDesignSlot.chosenPartName
  if not partName or partName == "" then return nil end

  local prefix = vehicleObj.JBeam .. "_skin_"
  if not string.startswith(partName, prefix) then return nil end

  return string.sub(partName, #prefix + 1)
end

local function initBlankLivery()
  local vehicleObj = getPlayerVehicle(0)
  local vehicleColor = vehicleObj and vehicleObj.color
  if not vehicleColor then
    log("E", "liveries", "unable to start a blank livery, no player vehicle to take the color from")
    return false
  end

  return ui_liveries_fill.setup(vehicleColor)
end

-- either the layer stack of an existing save, or a blank livery on the vehicle's own color
local function initLayerStack(saveName)
  api.clearLayerStack()

  ui_liveries_saves.clearCurrentSave()

  if not saveName then
    return initBlankLivery()
  end

  if ui_liveries_saves.load(saveName) then
    return ui_liveries_fill.bindLoadedLayer()
  end

  api.clearLayerStack()
  initBlankLivery()
  return false
end

M.setup = function(saveName)
  if isRunning then return true end

  if not api then
    log("E", "liveries", "dynamic decals api not available")
    return false
  end

  skinBeforeSetup = getCurrentSkin()

  -- the live decal cursor is only shown while the transform screen requests it
  api.setProjectDynamicDecalsState(false)

  api.setLayerNameBuildString("@type { - @colormap}")
  api.setup()
  core_vehicle_partmgmt.setSkin(dynamicTexturesSkin)

  local success = initLayerStack(saveName)

  api.getHistory():clear()
  api.onUpdate_()

  api.setEnabled(true)

  ui_liveries_camera.setup()

  isRunning = true
  return success
end

M.teardown = function()
  if not isRunning then return end

  ui_liveries_camera.teardown()

  if api then
    api.setProjectDynamicDecalsState(false)
    api.setEnabled(false)
  end

  core_vehicle_partmgmt.setSkin(skinBeforeSetup)
  ui_liveries_fill.teardown()

  skinBeforeSetup = nil
  isRunning = false
end

M.onUpdate = function(dtReal, dtSim, dtRaw)
  if not isRunning then return end

  if api then
    api.onUpdate_()
  end
end

M.isRunning = function()
  return isRunning
end

return M
