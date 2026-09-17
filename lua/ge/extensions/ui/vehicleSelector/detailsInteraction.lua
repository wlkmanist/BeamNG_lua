local M = {}

M.dependencies = {
  "ui_vehicleSelector_vehicleOperations",
  "ui_vehicleSelector_vehicleSpecifications",
}

-- Configuration
M.managementButtonsEnabled = true
M.customDetailsButtons = {}

-- Coordinate between modules
local function getDetails(itemDetails)
  -- Get specifications from vehicleSpecifications module
  local details = ui_vehicleSelector_vehicleSpecifications.getDetails(itemDetails)

  -- Get button info from vehicleOperations module
  local buttonInfo = {}

  -- Use custom details buttons if provided (for challenge mode)
  if M.customDetailsButtons and next(M.customDetailsButtons) then
    for _, button in ipairs(M.customDetailsButtons) do
      table.insert(buttonInfo, ui_vehicleSelector_vehicleOperations.addButton(function(additionalData)
        if not additionalData then
          additionalData = { }
          -- pre-fill additional data with the default paints
          local model = core_vehicles.getModel(details.modelKey)
          if model then
            -- Use config defaults if available, otherwise fall back to model defaults
            local config = model.configs[details.configKey]
            if config then
              additionalData.paint = config.defaultPaintName1 or model.defaultPaintName1
              additionalData.paint2 = config.defaultPaintName2 or model.defaultPaintName2
              additionalData.paint3 = config.defaultPaintName3 or model.defaultPaintName3
            else
              additionalData.paint = model.defaultPaintName1
              additionalData.paint2 = model.defaultPaintName2
              additionalData.paint3 = model.defaultPaintName3
            end
          end
        end
        button.callback(details.modelKey, details.configKey, additionalData)
      end, button.meta))
    end
  else
    -- Use standard button info for freeroam mode
    buttonInfo = ui_vehicleSelector_vehicleOperations.makeSpawningButtons(details.configDetails, ui_vehicleSelector_general.isSpawnOnly())
  end

  details.buttonInfo = buttonInfo
  return details
end

local function getManagementDetails()
  return ui_vehicleSelector_vehicleOperations.getManagementDetails()
end

local function setExitCallback(callback)
  M.exitCallback = callback or nop
end
M.setExitCallback = setExitCallback
M.exitCallback = nop

local function exploreFolder(path)
  Engine.Platform.exploreFolder(path)
end
M.exploreFolder = exploreFolder

local function goToMod(modId)
  guihooks.trigger('ChangeState', {state = 'menu.mods.details', params = {modId = modId}})
end

M.goToMod = goToMod
M.getDetails = getDetails
M.getManagementDetails = getManagementDetails

-- Expose sub-module functions through main interface
M.executeButton = function(...) return ui_vehicleSelector_vehicleOperations.executeButton(...) end
M.executeDoubleClick = function(...) return ui_vehicleSelector_vehicleOperations.executeDoubleClick(...) end
M.setManagementButtonsEnabled = function(...) return ui_vehicleSelector_vehicleOperations.setManagementButtonsEnabled(...) end
M.setDetailsButtonForFreeroam = function(...) return ui_vehicleSelector_vehicleOperations.setDetailsButtonForFreeroam(...) end
M.setCustomDetailsButtons = function(buttons) M.customDetailsButtons = buttons end
return M