-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "freeformDelivery_debug"
M.dependencies = { 'ui_imgui', 'gameplay_freeformDelivery_utils' }

local debugWindowOpen = false
local debugData = {}
local enableDebugWindow = false

local im = ui_imgui

local function formatTime(seconds)
  if not seconds then return "N/A" end
  local minutes = math.floor(seconds / 60)
  local secs = seconds % 60
  return string.format("%02d:%06.3f", minutes, secs)
end

local function drawDeliveryState()
  im.TextColored(im.ImVec4(1, 1, 0, 1), "=== DELIVERY STATE ===")

  local mainDelivery = gameplay_freeformDelivery_freeformDelivery
  local isLoaded = mainDelivery.isLoaded()
  local isActive = mainDelivery.isActive()

  im.Text("Loaded: " .. (isLoaded and "Yes" or "No"))
  im.Text("Active: " .. (isActive and "Yes" or "No"))
  im.Text("Setup Pending: " .. (debugData.setupPending and "Yes" or "No"))
  im.Text("Setup In Progress: " .. (debugData.setupInProgress and "Yes" or "No"))

  if debugData.deliveryName then
    im.Text("Name: " .. debugData.deliveryName)
  end
  if debugData.deliveryPath then
    im.Text("Path: " .. debugData.deliveryPath)
  end

  if debugData.elapsedTime then
    im.Text("Elapsed Time: " .. formatTime(debugData.elapsedTime))
  end

  if debugData.completionTimer then
    im.TextColored(im.ImVec4(0, 1, 0, 1), "Completion Timer: " .. string.format("%.2f", debugData.completionTimer) .. "s")
  end

  im.Separator()
end

local function drawSetupState()
  if not debugData.setupInProgress and not debugData.hasCouplings then return end

  im.TextColored(im.ImVec4(0.8, 0.8, 0, 1), "=== SETUP STATE ===")

  if debugData.setupInProgress then
    im.TextColored(im.ImVec4(1, 1, 0, 1), "Setup In Progress...")

    -- Check vehicle readiness
    if debugData.vehiclesNotReady and #debugData.vehiclesNotReady > 0 then
      im.Text("Vehicles Not Ready: " .. #debugData.vehiclesNotReady)
      if im.CollapsingHeader1("Not Ready Vehicles", im.TreeNodeFlags_DefaultOpen) then
        for _, vehId in ipairs(debugData.vehiclesNotReady) do
          im.Text("  - Vehicle ID: " .. tostring(vehId))
        end
      end
    else
      im.TextColored(im.ImVec4(0, 1, 0, 1), "All Vehicles Ready")
    end
  else
    im.TextColored(im.ImVec4(0, 1, 0, 1), "Setup Complete")
  end

  im.Separator()
end

local function drawCouplings()
  if not debugData.hasCouplings then return end

  im.TextColored(im.ImVec4(1, 0.5, 0, 1), "=== COUPLINGS ===")
  im.Text("Total Requested: " .. (debugData.totalCouplings or 0))
  im.Text("Pending: " .. (debugData.pendingCouplingCount or 0))

  if debugData.pendingCouplings and #debugData.pendingCouplings > 0 then
    im.TextColored(im.ImVec4(1, 1, 0, 1), "Pending Couplings:")
    if im.CollapsingHeader1("Pending Details", im.TreeNodeFlags_DefaultOpen) then
      for _, vehId in ipairs(debugData.pendingCouplings) do
        im.Text("  - Vehicle ID: " .. tostring(vehId))
      end
    end
  end

  if debugData.couplingSetup and #debugData.couplingSetup > 0 then
    if im.CollapsingHeader1("Coupling Setup Details", im.TreeNodeFlags_DefaultOpen) then
      for i, coupling in ipairs(debugData.couplingSetup) do
        local color = im.ImVec4(1, 1, 1, 1)
        -- Check if coupling is complete
        local isComplete = true
        if core_trailerRespawn then
          local trailerData = core_trailerRespawn.getTrailerData()
          if trailerData then
            local vehId = coupling.vehId
            local targetVehId = coupling.targetVehId
            local coupled = false
            if trailerData[vehId] and type(trailerData[vehId]) == "table" and trailerData[vehId].trailerId == targetVehId then
              coupled = true
            elseif trailerData[targetVehId] and type(trailerData[targetVehId]) == "table" and trailerData[targetVehId].trailerId == vehId then
              coupled = true
            end
            isComplete = coupled
            if isComplete then
              color = im.ImVec4(0, 1, 0, 1) -- Green for complete
            else
              color = im.ImVec4(1, 1, 0, 1) -- Yellow for pending
            end
          end
        end

        local status = isComplete and "[COMPLETE]" or "[PENDING]"
        im.TextColored(color, string.format("%d. %s -> %s %s", i, tostring(coupling.vehId), tostring(coupling.targetVehId), status))
        if coupling.nodeTag then
          im.SameLine()
          im.Text(" (Node: " .. coupling.nodeTag .. ")")
        end
      end
    end
  end

  im.Separator()
end

local function drawVehicles()
  if not debugData.vehicles or #debugData.vehicles == 0 then return end

  im.TextColored(im.ImVec4(0, 1, 0, 1), "=== VEHICLES ===")
  im.Text("Total: " .. #debugData.vehicles)

  if im.CollapsingHeader1("Vehicle Details", im.TreeNodeFlags_DefaultOpen) then
    for i, vehData in ipairs(debugData.vehicles) do
      local color = im.ImVec4(1, 1, 1, 1)
      if vehData.isPlayerVehicle then
        color = im.ImVec4(1, 1, 0, 1) -- Yellow for player vehicle
      end

      local vehText = string.format("%d. %s", i, vehData.name or vehData.id or "Unknown")
      if vehData.isPlayerVehicle then
        vehText = vehText .. " [PLAYER]"
      end
      if vehData.enterable == false then
        vehText = vehText .. " [NOT ENTERABLE]"
      end

      im.TextColored(color, vehText)

      if vehData.position then
        im.SameLine()
        im.TextColored(color, string.format("(%.1f, %.1f, %.1f)", vehData.position.x, vehData.position.y, vehData.position.z))
      end

      if vehData.damage ~= nil then
        im.SameLine()
        local damageColor = im.ImVec4(1, 1, 1, 1)
        if vehData.damage > 5000 then
          damageColor = im.ImVec4(1, 0, 0, 1) -- Red for high damage
        elseif vehData.damage > 1000 then
          damageColor = im.ImVec4(1, 0.5, 0, 1) -- Orange for medium damage
        end
        im.TextColored(damageColor, string.format(" [Damage: %.0f]", vehData.damage))
      end
    end
  end
  im.Separator()
end

local function drawGoals()
  if not debugData.goals or #debugData.goals == 0 then return end

  im.TextColored(im.ImVec4(0.5, 0.5, 1, 1), "=== GOALS ===")
  im.Text("Total: " .. #debugData.goals)
  im.Text("Completed: " .. (debugData.completedGoals or 0) .. "/" .. #debugData.goals)

  if im.CollapsingHeader1("Goal Details", im.TreeNodeFlags_DefaultOpen) then
    for i, goalData in ipairs(debugData.goals) do
      local color = im.ImVec4(1, 1, 1, 1)
      if goalData.completed then
        color = im.ImVec4(0, 1, 0, 1) -- Green for completed
      elseif goalData.active then
        color = im.ImVec4(1, 1, 0, 1) -- Yellow for active
      else
        color = im.ImVec4(0.5, 0.5, 0.5, 1) -- Gray for inactive
      end

      local goalText = string.format("%d. %s [%s]", i, goalData.id or "Unknown", goalData.type or "unknown")
      if goalData.completed then
        goalText = goalText .. " [COMPLETED]"
      elseif not goalData.active then
        goalText = goalText .. " [INACTIVE]"
      end
      if not goalData.required then
        goalText = goalText .. " [OPTIONAL]"
      end

      im.TextColored(color, goalText)

      if goalData.label then
        im.SameLine()
        im.TextColored(color, " - " .. goalData.label)
      end

      -- Show progress for multi-vehicle goals
      if goalData.progress then
        im.SameLine()
        im.TextColored(color, string.format(" (%d/%d)", goalData.progress.completed or 0, goalData.progress.total or 0))
      end

      -- Show prerequisites
      if goalData.requires and #goalData.requires > 0 then
        local reqTexts = {}
        for _, req in ipairs(goalData.requires) do
          local reqId = type(req) == "string" and req or req.id
          local reqState = type(req) == "table" and req.state or nil
          if reqState then
            table.insert(reqTexts, reqId .. ":" .. reqState)
          else
            table.insert(reqTexts, reqId)
          end
        end
        im.Text("  Requires: " .. table.concat(reqTexts, ", "))
      end

      -- Show target area for placement goals
      if goalData.type == "placement" and goalData.targetAreaId then
        im.Text("  Target Area: " .. goalData.targetAreaId)
      end

      -- Show vehicle for damage goals
      if goalData.type == "damage" and goalData.vehicleId then
        im.Text("  Vehicle: " .. goalData.vehicleId)
        if goalData.maxDamage then
          im.Text("  Max Damage: " .. string.format("%.0f", goalData.maxDamage))
        end
      end
    end
  end
  im.Separator()
end

local function drawTargetAreas()
  if not debugData.targetAreas or #debugData.targetAreas == 0 then return end

  im.TextColored(im.ImVec4(1, 0.8, 0, 1), "=== TARGET AREAS ===")
  im.Text("Total: " .. #debugData.targetAreas)

  if im.CollapsingHeader1("Area Details", im.TreeNodeFlags_DefaultOpen) then
    for i, areaData in ipairs(debugData.targetAreas) do
      local color = im.ImVec4(1, 1, 1, 1)
      if areaData.type == "location" then
        color = im.ImVec4(0, 1, 1, 1) -- Cyan for locations
      elseif areaData.type == "zone" then
        color = im.ImVec4(0, 1, 0, 1) -- Green for zones
      elseif areaData.type == "parkingSpot" then
        color = im.ImVec4(1, 0.5, 0, 1) -- Orange for parking spots
      end

      local areaText = string.format("%d. %s [%s]", i, areaData.id or "Unknown", areaData.type or "unknown")
      if areaData.siteId then
        areaText = areaText .. " (Site: " .. areaData.siteId .. ")"
      end

      im.TextColored(color, areaText)

      if areaData.position then
        im.SameLine()
        im.TextColored(color, string.format("(%.1f, %.1f, %.1f)", areaData.position.x, areaData.position.y, areaData.position.z))
      end
    end
  end
  im.Separator()
end

local function drawRoutes()
  if not debugData.routes then return end

  im.TextColored(im.ImVec4(1, 0, 1, 1), "=== ROUTES ===")
  im.Text("Available: " .. (debugData.routeCount or 0))

  if debugData.currentRoute then
    im.TextColored(im.ImVec4(0, 1, 0, 1), "Current Route: " .. debugData.currentRoute)
  else
    im.Text("Current Route: None")
  end

  if debugData.routes and #debugData.routes > 0 and im.CollapsingHeader1("Route Details", im.TreeNodeFlags_DefaultOpen) then
    for i, routeData in ipairs(debugData.routes) do
      local color = im.ImVec4(1, 1, 1, 1)
      if debugData.currentRoute and (routeData.targetAreaId == debugData.currentRoute or routeData.vehicleId == debugData.currentRoute) then
        color = im.ImVec4(0, 1, 0, 1) -- Green for active route
      end

      local routeText = string.format("%d. ", i)
      if routeData.targetAreaId then
        routeText = routeText .. "Area: " .. routeData.targetAreaId
      elseif routeData.vehicleId then
        routeText = routeText .. "Vehicle: " .. routeData.vehicleId
      end

      im.TextColored(color, routeText)
    end
  end
  im.Separator()
end

local function drawParkingInfo()
  if not debugData.parkingInfo or #debugData.parkingInfo == 0 then return end

  im.TextColored(im.ImVec4(1, 0.5, 0, 1), "=== PARKING INFO ===")
  im.Text("Vehicles in Parking Spots: " .. #debugData.parkingInfo)

  if im.CollapsingHeader1("Parking Details", im.TreeNodeFlags_DefaultOpen) then
    for i, parkingData in ipairs(debugData.parkingInfo) do
      local color = im.ImVec4(1, 1, 1, 1)
      if parkingData.cornerCount ~= nil then
        if parkingData.cornerCount == 4 then
          color = im.ImVec4(0, 1, 0, 1) -- Green for all corners
        elseif parkingData.cornerCount >= 1 then
          color = im.ImVec4(1, 1, 0, 1) -- Yellow for at least one but not all corners
        else
          color = im.ImVec4(1, 0.5, 0, 1) -- Orange for no corners
        end
      end

      im.TextColored(color, string.format("%d. %s in %s", i, parkingData.vehicleId or "Unknown", parkingData.spotId or "Unknown"))

      -- Overall status
      if parkingData.valid then
        im.TextColored(im.ImVec4(0, 1, 0, 1), "  Status: VALID PARKING")
      else
        im.TextColored(im.ImVec4(1, 0, 0, 1), "  Status: INVALID PARKING")
      end

      -- Corner validation (from checkParking)
      if parkingData.cornerCount ~= nil then
        local cornerColor = im.ImVec4(1, 1, 1, 1)
        if parkingData.cornerCount == 4 then
          cornerColor = im.ImVec4(0, 1, 0, 1) -- Green for all corners
        elseif parkingData.cornerCount >= 1 then
          cornerColor = im.ImVec4(1, 1, 0, 1) -- Yellow for at least one but not all corners
        else
          cornerColor = im.ImVec4(1, 0, 0, 1) -- Red for no corners
        end
        im.TextColored(cornerColor, string.format("  Corners in spot: %d/4", parkingData.cornerCount))

        -- Show which corners are in the spot
        if parkingData.corners then
          local cornerLabels = { "Front-Left", "Front-Right", "Back-Left", "Back-Right" }
          local cornerDetails = {}
          for j, cornerIn in ipairs(parkingData.corners) do
            if cornerIn then
              table.insert(cornerDetails, cornerLabels[j])
            end
          end
          if #cornerDetails > 0 then
            im.Text(string.format("    Corners: %s", table.concat(cornerDetails, ", ")))
          end
        end
      end

      -- Parking spot size
      if parkingData.spotSize then
        im.Text(string.format("  Spot size: %.2fm x %.2fm x %.2fm", parkingData.spotSize.x, parkingData.spotSize.y, parkingData.spotSize.z))
      end

      im.Separator()
    end
  end
  im.Separator()
end

local function formatDistance(distance)
  if distance == nil or distance == math.huge then
    return "N/A"
  end
  return string.format("%.1fm", distance)
end

local function drawVehicleSleep()
  if not debugData.vehicleSleep or #debugData.vehicleSleep == 0 then return end

  im.TextColored(im.ImVec4(0.6, 0.9, 1, 1), "=== VEHICLE SLEEP ===")
  im.Text("Tracked Vehicles: " .. #debugData.vehicleSleep)

  if im.CollapsingHeader1("Sleep Details", im.TreeNodeFlags_DefaultOpen) then
    for i, sleepData in ipairs(debugData.vehicleSleep) do
      local color = sleepData.sleeping and im.ImVec4(1, 0.6, 0, 1) or im.ImVec4(0, 1, 0, 1)
      local status = sleepData.sleeping and "SLEEPING" or "ACTIVE"
      im.TextColored(color, string.format("%d. %s [%s]", i, tostring(sleepData.id), status))
      im.Text(string.format("  Sleep: %.1fm  Wake: %.1fm", sleepData.sleepDistance or 0, sleepData.wakeDistance or 0))
      im.Text("  Camera Distance: " .. formatDistance(sleepData.cameraDistance))
      im.Text("  Player Vehicle Distance: " .. formatDistance(sleepData.playerVehicleDistance))
    end
  end

  im.Separator()
end

local function drawDebugWindow()
  if not enableDebugWindow then
    return
  end

  im.Begin("Freeform Delivery Debug", im.BoolPtr(true))

  if not debugData.hasDelivery then
    im.Text("No delivery loaded")
    im.End()
    return
  end

  drawDeliveryState()
  drawSetupState()
  drawCouplings()
  drawVehicles()
  drawGoals()
  drawTargetAreas()
  drawRoutes()
  drawParkingInfo()
  drawVehicleSleep()

  im.End()
end

local function updateDebugData()
  if not enableDebugWindow then return end

  local mainDelivery = gameplay_freeformDelivery_freeformDelivery
  local isLoaded = mainDelivery.isLoaded()
  local isActive = mainDelivery.isActive()
  local currentDelivery = mainDelivery.getCurrentDelivery()

  -- Show debug window if delivery is loaded (even if not active yet) or if there's a current delivery
  if not isLoaded and not isActive and not currentDelivery then
    debugData = { hasDelivery = false }
    return
  end

  debugData.hasDelivery = true
  debugData.setupPending = mainDelivery.getSetupPending()
  debugData.isLoaded = isLoaded
  debugData.isActive = isActive

  -- Get setup state
  debugData.setupInProgress = gameplay_freeformDelivery_setup.isSetupInProgress()

  -- Get pending couplings
  local pendingCouplings = gameplay_freeformDelivery_setup.getPendingCouplings()
  debugData.pendingCouplings = pendingCouplings
  debugData.pendingCouplingCount = #pendingCouplings

  -- Get all coupling setup
  local couplingSetup = gameplay_freeformDelivery_setup.getAllCouplingSetup()
  debugData.couplingSetup = couplingSetup
  debugData.totalCouplings = #couplingSetup
  debugData.hasCouplings = #couplingSetup > 0

  -- Check vehicle readiness
  if debugData.setupInProgress then
    local spawnedVehicles = gameplay_freeformDelivery_setup.getSpawnedVehicles()
    debugData.vehiclesNotReady = {}
    for vehId, vehicleData in pairs(spawnedVehicles) do
      local veh = getObjectByID(vehId)
      if not veh or not veh:isReady() then
        table.insert(debugData.vehiclesNotReady, vehId)
      end
    end
  end

  if currentDelivery then
    debugData.deliveryName = currentDelivery.name
    debugData.deliveryPath = currentDelivery._loadedPath

    -- Get elapsed time
    if isActive then
      local startTime = mainDelivery.getStartTime()
      if startTime and startTime > 0 then
        debugData.elapsedTime = os.clock() - startTime
      end
    end

    -- Get completion timer from goals
    debugData.completionTimer = gameplay_freeformDelivery_goals.getCompletionTimer()

    -- Get vehicles
    debugData.vehicles = {}
    if currentDelivery.vehicles then
      local playerVeh = gameplay_freeformDelivery_utils.getPlayerVehicle()
      local playerVehId = playerVeh and playerVeh:getId() or nil

      for _, vehicleDef in ipairs(currentDelivery.vehicles) do
        local veh = gameplay_freeformDelivery_utils.getVehicleObjectByDeliveryId(vehicleDef.id)
        if veh then
            local vehId = veh:getId()
            local vehData = {
              id = vehicleDef.id,
              name = vehicleDef.name or vehicleDef.id,
              enterable = vehicleDef.enterable,
              isPlayerVehicle = (vehId == playerVehId),
              damage = veh.damage
            }

            -- Get position
            local pos = veh:getPosition()
            if pos then
              vehData.position = { x = pos.x, y = pos.y, z = pos.z }
            end

            table.insert(debugData.vehicles, vehData)
        end
      end
    end

    -- Get goals
    debugData.goals = {}
    debugData.completedGoals = 0
    local allGoals = gameplay_freeformDelivery_goals.getAllGoals()

    for goalId, goal in pairs(allGoals) do
      local state = gameplay_freeformDelivery_goals.getGoalState(goalId) or {}
      local goalProgress = gameplay_freeformDelivery_goals.getGoalProgress(goalId)

        local goalData = {
          id = goalId,
          type = goal.type,
          label = goal.label,
          completed = state.completed or false,
          active = state.active ~= false, -- Default to true if not specified
          required = goal.required ~= false,
          requires = goal.requires,
          targetAreaId = goal.targetAreaId,
          vehicleId = goal.vehicleId,
          maxDamage = goal.maxDamage,
          order = goal.order or 0
        }

        if goalProgress then
          goalData.progress = {
            completed = goalProgress.inArea or 0,
            total = goalProgress.total or 0
          }
        end

        if goalData.completed then
          debugData.completedGoals = debugData.completedGoals + 1
        end

      table.insert(debugData.goals, goalData)
    end

    table.sort(debugData.goals, function(a, b) return (a.order or 0) < (b.order or 0) end)

    -- Get target areas
    debugData.targetAreas = {}
    if currentDelivery.targetAreas then
      for _, area in ipairs(currentDelivery.targetAreas) do
        local areaData = {
          id = area.id,
          type = area.type,
          siteId = area.siteId
        }

        -- Get position
        local pos = gameplay_freeformDelivery_routes.getTargetAreaPosition(area.id)
        if pos then
          areaData.position = { x = pos.x, y = pos.y, z = pos.z }
        end

        table.insert(debugData.targetAreas, areaData)
      end
    end

    -- Get routes
    debugData.routes = gameplay_freeformDelivery_routes.getRoutes()
    debugData.routeCount = gameplay_freeformDelivery_routes.getRouteCount()

    -- Get current route
    local currentRoute = gameplay_freeformDelivery_routes.getCurrentRoute()
    if currentRoute then
      if currentRoute.targetAreaId then
        debugData.currentRoute = currentRoute.targetAreaId
      elseif currentRoute.vehicleId then
        debugData.currentRoute = currentRoute.vehicleId
      end
    end

    if gameplay_freeformDelivery_vehicleSleep and gameplay_freeformDelivery_vehicleSleep.getDebugData then
      debugData.vehicleSleep = gameplay_freeformDelivery_vehicleSleep.getDebugData()
    else
      debugData.vehicleSleep = {}
    end

    -- Get parking information for vehicles in parking spots
    debugData.parkingInfo = {}
    if currentDelivery.targetAreas and currentDelivery.sites then
      for _, targetArea in ipairs(currentDelivery.targetAreas) do
        if targetArea.type == "parkingSpot" then
          local siteObj = gameplay_freeformDelivery_utils.findSiteObject(currentDelivery.sites, targetArea.type, targetArea.siteId)
          if siteObj then
            -- Check all vehicles to see if they're in this parking spot
            if currentDelivery.vehicles then
              for _, vehicleDef in ipairs(currentDelivery.vehicles) do
                local veh = gameplay_freeformDelivery_utils.getVehicleObjectByDeliveryId(vehicleDef.id)
                if veh then
                  local parkingInfo = gameplay_freeformDelivery_utils.getParkingInfo(veh, siteObj)
                  if parkingInfo then
                    table.insert(debugData.parkingInfo, {
                      vehicleId = vehicleDef.id,
                      vehicleName = vehicleDef.name or vehicleDef.id,
                      spotId = targetArea.id,
                      spotName = targetArea.siteId,
                      valid = parkingInfo.valid,
                      cornerCount = parkingInfo.cornerCount,
                      corners = parkingInfo.corners,
                      spotSize = parkingInfo.spotSize
                    })
                  end
                end
              end
            end
          end
        end
      end
    end
  else
    debugData.hasDelivery = false
  end
end

local function onPreRender(dtReal, dtSim, dtRaw)
  if not enableDebugWindow then return end

  updateDebugData()
  drawDebugWindow()
end

M.setEnableDebugWindow = function(enabled)
  enableDebugWindow = enabled
  if not enabled then
    debugWindowOpen = false
    debugData = {}
  end
  log('D', logTag, 'Debug window ' .. (enabled and 'enabled' or 'disabled'))
end

M.getEnableDebugWindow = function()
  return enableDebugWindow
end

M.toggleDebugWindow = function()
  debugWindowOpen = not debugWindowOpen
  log('D', logTag, 'Debug window ' .. (debugWindowOpen and 'opened' or 'closed'))
end

M.clearDebugData = function()
  debugData = {}
  log('D', logTag, 'Debug data cleared')
end

M.onPreRender = onPreRender

return M
