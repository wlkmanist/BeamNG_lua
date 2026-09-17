
local M = {}

local originComputerId = nil

local function openPlayerAbstractMenu(_originComputerId)
  originComputerId = _originComputerId
  if originComputerId then
    extensions.ui_router.navigate("career.computer.playerAbstract")
    extensions.hook("onComputerPlayerAbstract")
  end
end

local function onComputerAddFunctions(menuData, computerFunctions)
  if menuData.computerFacility.functions["playerAbstract"] then
    local computerFunctionData = {
      id = "playerAbstract",
      routeTarget = "career.computer.playerAbstract",
      label = _tr("ui.career.driverAbstract.title"),
      callback = function() openPlayerAbstractMenu(menuData.computerFacility.id) end,
      order = 15
    }
    if not menuData.hasBoughtStarterVehicle then
      computerFunctionData.disabled = true
      computerFunctionData.reason = career_modules_computer.reasons.hasBoughtStarterVehicle
    end
    computerFunctions.general[computerFunctionData.id] = computerFunctionData
  end
end

local function closePlayerAbstractMenu()
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    career_modules_computer.openMenu(computer)
  else
    career_career.closeAllMenus()
  end
end

local function getPlayerAbstractData()
  return career_modules_insurance_insurance.getPlayerAbstractData()
end

-- Router lifecycle: attach the player abstract data into routeData so the UI
-- reads it from the routeData store instead of fetching it on mount.
local function onRouteMount(context, toRoute, fromRoute, data)
  data.playerAbstract = getPlayerAbstractData()
end

-- Router lifecycle: clear route-local state when leaving the screen.
local function onRouteLeave(context, toRoute, fromRoute, data)
  originComputerId = nil
end

-- Push fresh abstract data to an already-open screen (e.g. after a score reset).
local function sendPlayerAbstractDataToUI()
  guihooks.trigger("playerAbstractData", getPlayerAbstractData())
end

M.openPlayerAbstractMenu = openPlayerAbstractMenu
M.getPlayerAbstractData = getPlayerAbstractData
M.sendPlayerAbstractDataToUI = sendPlayerAbstractDataToUI
M.onComputerAddFunctions = onComputerAddFunctions
M.closePlayerAbstractMenu = closePlayerAbstractMenu
M.onRouteMount = onRouteMount
M.onRouteLeave = onRouteLeave

return M