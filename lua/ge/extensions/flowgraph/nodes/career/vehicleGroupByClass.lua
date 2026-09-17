-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.vehicleClassGrouping
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

C.name = 'Vehicle Group by Performance Class'
C.description = 'Generates a vehicle group based on the given class.'
C.category = 'once_instant'
C.color = ui_flowgraph_editor.nodeColors.career
C.icon = ui_flowgraph_editor.nodeIcons.career
C.author = 'BeamNG'
C.dependencies = {'career_modules_vehicleClassGrouping', 'gameplay_vehiclePerformance'}

C.pinSchema = {
  {dir = 'in', type = {'string', 'number'}, name = 'class', description = 'Vehicle performance class; string name or numeric class index.'},
  {dir = 'out', type = 'table', name = 'vehGroup', tableType = 'vehicleGroupData', description = 'Vehicle group data.'},
  {dir = 'out', type = 'number', name = 'aggressionCoef', description = 'Vehicle AI aggression multiplier.'}
}

C.tags = {'career', 'race', 'class', 'vehicle'}

function C:workOnce()
  local class = self.pinIn.class.value

  if type(class) == 'number' then
    local classNames = gameplay_vehiclePerformance.getClassNames()
    class = classNames[clamp(math.floor(class), 1, #classNames)]
  end

  -- If the active mission provides its own class-aware group generator (e.g. to
  -- apply the editor's "Vehicle Selection Filters" on top of the class match),
  -- defer to it. Otherwise fall back to the default class-based group.
  local mission = self.mgr and self.mgr.activity
  if mission and type(mission.generateVehicleGroup) == 'function' then
    self.pinOut.vehGroup.value = mission:generateVehicleGroup(class)
  else
    self.pinOut.vehGroup.value = career_modules_vehicleClassGrouping.generateGroup(class)
  end
  self.pinOut.aggressionCoef.value = career_modules_vehicleClassGrouping.getAggressionMultiplier(class)
end

return _flowgraph_createNode(C)
