-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Select Garage Sites'
C.description = 'Selects start and destination parking spots from initial and destination zones with used position tracking.'
C.category = 'once_instant'
C.author = 'BeamNG'

C.pinSchema = {
  {dir = 'out', type = 'flow', name = 'loaded', default = false, description= 'Triggers once after the spots are found.', impulse = true},

  {dir = 'in', type = 'table', name = 'sitesData', description = 'Sites data'},
  {dir = 'in', type = 'number', name = 'minDist', description = 'Minimum distance between start and end spots' },
  {dir = 'in', type = 'number', name = 'maxDist', description = 'Maximum distance between start and end spots' },

  {dir = 'out', type = 'string', name = 'startSpot', description = 'Selected start parking spot name'},
  {dir = 'out', type = 'string', name = 'endSpot', description = 'Selected end parking spot name'},
  {dir = 'out', type = 'string', name = 'startLocation', description = 'Zone name of start location'},
  {dir = 'out', type = 'string', name = 'endLocation', description = 'Zone name of end location'},
}
C.color = ui_flowgraph_editor.nodeColors.scene
C.icon = ui_flowgraph_editor.nodeIcons.scene
C.tags = {}

function C:init()
  self.startSpot = nil
  self.endSpot = nil
  self.state = 1
  self.usedStartSpots = {}
  self.usedEndSpots = {}

  self.pinOut.loaded.value = false

  self.pinOut.startSpot.value = nil
  self.pinOut.endSpot.value = nil
end

function C:_executionStarted()
  -- Don't reset used lists, only reset state and outputs
  self.startSpot = nil
  self.endSpot = nil
  self.state = 1

  self.pinOut.loaded.value = false

  self.pinOut.startSpot.value = nil
  self.pinOut.endSpot.value = nil
end

function C:resetData()
  -- Don't reset used lists - keep them persistent
  self.startSpot = nil
  self.endSpot = nil
  self.state = 1

  self.pinOut.loaded.value = false

  self.pinOut.startSpot.value = nil
  self.pinOut.endSpot.value = nil
end

function C:workOnce()
  self:resetData()
end

-- Get parking spots that belong to the specified zones
local function getSpotsInZones(sitesData, zoneNames)
  local spots = {}
  local zoneSet = {}
  for _, zoneName in ipairs(zoneNames) do
    zoneSet[zoneName] = true
  end

  if not sitesData or not sitesData.parkingSpots or not sitesData.parkingSpots.byName then
    return spots
  end

  for spotName, spot in pairs(sitesData.parkingSpots.byName) do
    if spot.zones then
      for _, zone in ipairs(spot.zones) do
        if zoneSet[zone.name] then
          table.insert(spots, {name = spotName, spot = spot})
          break
        end
      end
    end
  end

  return spots
end

function C:findEndSpotForStartingSpot(startSpot, possibleEndSpots)
  -- Shuffle end spots
  for i = #possibleEndSpots, 2, -1 do
    local j = math.random(i)
    possibleEndSpots[i], possibleEndSpots[j] = possibleEndSpots[j], possibleEndSpots[i]
  end

  -- Best result if we find none that fit
  local bestCandidate = nil
  local bestOverDistance = nil

  -- Go through all the end spots
  for i = 1, #possibleEndSpots do
    local endSpotData = possibleEndSpots[i]
    local endSpot = endSpotData.spot

    if endSpot.name ~= startSpot.name then
      -- Check the distance to the startSpot
      local distance = (startSpot.pos - endSpot.pos):length()

      -- Return early if it fits our criteria
      if distance > self.pinIn.minDist.value and distance < self.pinIn.maxDist.value then
        log("D","","Found a good candidate after " .. i .. " tries")
        return endSpotData
      else
        -- Otherwise, keep track of the best result
        if not bestCandidate then
          bestCandidate = endSpotData
          bestOverDistance = distance - self.pinIn.maxDist.value
        else
          if distance - self.pinIn.maxDist.value < bestOverDistance then
            bestCandidate = endSpotData
            bestOverDistance = distance - self.pinIn.maxDist.value
          end
        end
      end
    end
  end

  log("D","","Could not find endSpot within acceptable distance! using best candidate")
  return bestCandidate
end

function C:work()
  if self.state == 1 then
    -- Get mission instance
    local mission = self.mgr.activity
    if not mission then
      log("E","SelectGarage2GarageZones","No mission instance available")
      return
    end

    -- Ensure zone lists are generated
    if not mission.initialZones or not mission.destinationZones then
      if mission.generateZoneLists then
        mission:generateZoneLists()
      else
        log("E","SelectGarage2GarageZones","Mission does not have zone lists or generateZoneLists method")
        return
      end
    end

    -- Get zones from mission
    local initialZoneNames = mission.initialZones or {}
    local destinationZoneNames = mission.destinationZones or {}

    if #initialZoneNames == 0 or #destinationZoneNames == 0 then
      log("E","SelectGarage2GarageZones","No initial or destination zones specified")
      return
    end

    -- Get parking spots in each zone set
    local possibleStartSpots = getSpotsInZones(self.pinIn.sitesData.value, initialZoneNames)
    local possibleEndSpots = getSpotsInZones(self.pinIn.sitesData.value, destinationZoneNames)

    if #possibleStartSpots == 0 or #possibleEndSpots == 0 then
      log("E","SelectGarage2GarageZones","No parking spots found in specified zones")
      return
    end

    -- Check if all start spots are used, reset if so
    if #possibleStartSpots == #self.usedStartSpots then
      table.clear(self.usedStartSpots)
      -- Change random seed for more randomness
      math.randomseed(os.time())
      log("D","","Cleared used start spots. Can now use all of them again")
    end

    -- Filter out used start spots
    local availableStartSpots = {}
    local usedStartSet = tableValuesAsLookupDict(self.usedStartSpots)
    for _, spotData in ipairs(possibleStartSpots) do
      if not usedStartSet[spotData.name] then
        table.insert(availableStartSpots, spotData)
      end
    end

    if #availableStartSpots == 0 then
      log("E","SelectGarage2GarageZones","No available start spots")
      return
    end

    -- Check if all end spots are used, reset if so
    if #possibleEndSpots == #self.usedEndSpots then
      table.clear(self.usedEndSpots)
      -- Change random seed for more randomness
      math.randomseed(os.time())
      log("D","","Cleared used end spots. Can now use all of them again")
    end

    -- Filter out used end spots
    local availableEndSpots = {}
    local usedEndSet = tableValuesAsLookupDict(self.usedEndSpots)
    for _, spotData in ipairs(possibleEndSpots) do
      if not usedEndSet[spotData.name] then
        table.insert(availableEndSpots, spotData)
      end
    end

    if #availableEndSpots == 0 then
      log("E","SelectGarage2GarageZones","No available end spots")
      return
    end

    -- Shuffle and select start spot
    for i = #availableStartSpots, 2, -1 do
      local j = math.random(i)
      availableStartSpots[i], availableStartSpots[j] = availableStartSpots[j], availableStartSpots[i]
    end

    local selectedStartData = availableStartSpots[1]
    self.startSpot = selectedStartData.spot

    -- Find matching end spot
    local selectedEndData = self:findEndSpotForStartingSpot(self.startSpot, availableEndSpots)
    if not selectedEndData then
      log("E","SelectGarage2GarageZones","Could not find suitable end spot")
      return
    end

    self.endSpot = selectedEndData.spot

    -- Track used spots
    table.insert(self.usedStartSpots, self.startSpot.name)
    table.insert(self.usedEndSpots, self.endSpot.name)

    -- Setup out pin values
    table.sort(self.startSpot.zones, function(a,b) return (a.customFields.values.prio or 1) < (b.customFields.values.prio or 1) end)
    table.sort(self.endSpot.zones, function(a,b) return (a.customFields.values.prio or 1) < (b.customFields.values.prio or 1) end)

    self.pinOut.startSpot.value = self.startSpot.name
    self.pinOut.endSpot.value = self.endSpot.name

    self.pinOut.startLocation.value = self.startSpot.zones[1] and self.startSpot.zones[1].name or ""
    self.pinOut.endLocation.value = self.endSpot.zones[1] and self.endSpot.zones[1].name or ""

    self.pinOut.loaded.value = true

    log("I","",string.format("G2G Route: %s/%s to %s/%s direct distance: %0.1f",
      self.pinOut.startSpot.value, self.pinOut.startLocation.value,
      self.pinOut.endSpot.value, self.pinOut.endLocation.value,
      (self.startSpot.pos - self.endSpot.pos):length()))
    self.state = 2
  elseif self.state == 2 then
    self.pinOut.loaded.value = false
  end
end

return _flowgraph_createNode(C)

