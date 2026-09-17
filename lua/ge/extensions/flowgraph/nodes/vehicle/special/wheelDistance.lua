-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

C.name = 'Wheel Distance'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.vehicle

C.description = "Gives the distance of the closest wheel center to a point."
C.category = 'repeat_p_duration'

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'vehId', description = 'Defines the id of the vehicle for calculation.' },
  { dir = 'in', type = 'vec3', name = 'position', description = 'Defines the position to calculate distance to.' },
  { dir = 'out', type = 'number', name = 'distance', description = 'Puts out the distance of the closest wheel center to the given point.' },
}
C.legacyPins = {
  _in = {
    vehID = 'vehId'
  }
}
C.tags = {}

local target, point, pointToTrigger, vehCenter, dirVec = vec3(), vec3(), vec3(), vec3(), vec3()
local wheelNodePos, wheelNodePosToTrigger = vec3(), vec3()
local wheels = {}

function C:init()
  self.data.debug = false
  self.data.onlyUseFrontWheels = true
end

local function getTwoSmallestValues(values)
  if not values[2] then return end -- two values not found, return nil

  local min1 = values[1]
  local min2 = values[2]

  if (min2.distance < min1.distance) then
    min1 = values[2]
    min2 = values[1]
  end

  for i=3, #values do
    if (values[i].distance < min1.distance) then
      min2 = min1
      min1 = values[i]
    elseif values[i].distance < min2.distance then
      min2 = values[i]
    end
  end

  if #values % 2 ~= 0 then
    return {min1, min1}
  end

  return {min1, min2}
end

function C:calculateDistanceFromStart(vehicle, target)
  if vehicle and target then
    table.clear(wheels)
    point:set(vehicle:getPosition())
    vehCenter:set(vehicle:getSpawnWorldOOBB():getCenter())
    dirVec:set(vehicle:getDirectionVector())
    -- We need to identify all vehicle wheels and then calculate the distance from the start line for each wheel
    for i = 0, vehicle:getWheelCount() - 1 do
      wheelNodePos:setAdd2(vehicle:getNodePosition(vehicle:getWheelAxisNodes(i)[1]), point)
      -- NOTE: nodePos alone is not good enough, vehicles such as the bus have the front wheels behind the ref node

      wheelNodePosToTrigger:setSub2(wheelNodePos, vehCenter) -- direction vector from vehicle center
      if not self.data.onlyUseFrontWheels or dirVec:dot(wheelNodePosToTrigger) > 0 then -- assumes front wheels if dot is positive
        wheelNodePosToTrigger:setSub2(wheelNodePos, target) -- direction vector from target position
        -- We need actual distance from starting line and not the center
        local dot = wheelNodePosToTrigger:normalized():dot(dirVec:normalized())
        local distance = (wheelNodePosToTrigger * dot):len()
        table.insert(wheels,{wheelNodePos = wheelNodePos, distance = distance})
      end
    end

    -- In order to accurately calculate that the vehicle is in the correct position
    -- we need to find the wheels that are closest to the start line
    local closestWheels = getTwoSmallestValues(wheels)
    if closestWheels then
      local wheel1 = closestWheels[1].wheelNodePos
      local wheel2 = closestWheels[2].wheelNodePos

      -- Point inbetween both wheels is calculated so that we can get a somewhat accurate distance measurement
      point:set((wheel1.x + wheel2.x)/2, (wheel1.y + wheel2.y)/2, (wheel1.z + wheel2.z)/2)
    end

    pointToTrigger:setSub2(point, target)
    pointToTrigger.z = 0
    local dot = pointToTrigger:dot(dirVec:normalized())
    local distanceFromStart = -dot --(vehicle:getDirectionVector() * dot):len()

    if self.data.debug and closestWheels then
      for k, v in pairs(closestWheels) do
          -- Line from each closest wheel to start line
        debugDrawer:drawLine(v.wheelNodePos, target, ColorF(0.5,0.0,0.5,1.0))
        debugDrawer:drawTextAdvanced(v.wheelNodePos, String('Distance:' .. v.distance), ColorF(0,0,0,1), true, false, ColorI(255, 255, 255, 255))
      end
      -- Line between two closest wheels
      debugDrawer:drawLine(closestWheels[1].wheelNodePos, closestWheels[2].wheelNodePos, ColorF(0.5,0.0,0.5,1.0))
      -- Sphere indicating center point of the wheels
      debugDrawer:drawSphere(point, 0.2, ColorF(0.0,0.0,1.0,1.0))
      -- Sphere indicating start line
      debugDrawer:drawLine(point, target, ColorF(1,0.0,0.5,1.0))
      -- Text to indicate current distance from start line
      debugDrawer:drawTextAdvanced(target, String('Distance:' .. distanceFromStart), ColorF(0,0,0,1), true, false, ColorI(255, 255, 255, 255))
    end
    print(tostring(distanceFromStart))

    return distanceFromStart
  end
end

function C:work()
  local veh
  if self.pinIn.vehId.value then
    veh = scenetree.findObjectById(self.pinIn.vehId.value)
  else
    veh = getPlayerVehicle(0)
  end
  if not veh or not self.pinIn.position.value then print("ERROR1") return end

  target:setFromTable(self.pinIn.position.value)
  self.pinOut.distance.value = self:calculateDistanceFromStart(veh, target)
end

function C:drawMiddle(builder, style)
  builder:Middle()
end

return _flowgraph_createNode(C)
