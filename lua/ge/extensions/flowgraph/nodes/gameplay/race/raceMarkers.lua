-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

C.name = 'Race Markers'
C.description = 'Displays the Race Markers for one Vehicle.'
C.category = 'repeat_instant'

C.color = im.ImVec4(1, 1, 0, 0.75)
C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'clear', description = 'Clears markers.', impulse = true },
  { dir = 'in', type = 'table', name = 'raceData', tableType = 'raceData', description = 'Data from the race for other nodes to process.' },
  { dir = 'in', type = 'number', name = 'vehId', description = 'The Vehicle that should be tracked.' },
  { dir = 'in', type = 'bool', name = 'ignoreRecovery', hidden = true, description = 'When true, recovery types are ignored.' },
  { dir = 'in', type = 'number', name = 'minAlpha', default = 0.15, hardcoded = true, hidden = true, description = 'Opacity when vehicle is closest.' },
  { dir = 'in', type = 'number', name = 'maxAlpha', default = 1, hardcoded = true, hidden = true, description = 'Opacity when vehicle is furthest.' },
  { dir = 'in', type = 'number', name = 'minDistance', default = 5, hardcoded = true, hidden = true, description = 'Distance for closest opacity.' },
  { dir = 'in', type = 'number', name = 'maxDistance', default = 50, hardcoded = true, hidden = true, description = 'Distance for furthest opacity.' },
  { dir = 'in', type = 'bool', name = 'alwaysShowFinal', hidden = true, description = 'Always show final Marker.' }
}

C.tags = { 'scenario' }

C.legacyPins = {
  _in = {
    reset = 'clear'
  }
}

local modeColors = {
  default = color(1*255, 0.07*255, 0*255, 255),
  next = color(0.0*255, 0.0*255, 0.0*255, 255),
  start = color(0.4*255, 1*255, 0.2*255, 255),
  lap = color(0.4*255, 1*255, 0.2*255, 255),
  recovery = color(1*255, 0.85*255, 0*255, 255),
  final = color(0.1*255, 0.3*255, 1*255, 255),
  branch = color(1*255, 0.6*255, 0*255, 255),
  hidden = color(64,64,64,192),
}

function C:init()
  self.markers = nil
  self.minimapMarkers = {}
  self.route = nil
end
function C:work()
  if self.pinIn.clear.value then
    self:_executionStopped()
  elseif self.pinIn.flow.value then
    if self.pinIn.raceData.value then
      if self.markers == nil then
        self.markers = require('scenario/race_marker')
        self.markers.init()
        local wps = {}
        for _, pn in ipairs(self.pinIn.raceData.value.path.pathnodes.sorted) do
          table.insert(wps, {name = pn.id, pos = pn.pos, radius = pn.radius, normal = pn.hasNormal and pn.normal or nil})
          self.minimapMarkers[pn.id] = {pos = pn.pos, color = modeColors['hidden'], mode = 'hidden'}
          if pn.hasNormal then
            local side = vec3(pn.normal.y, -pn.normal.x, 0):normalized() * pn.radius
            self.minimapMarkers[pn.id].left = pn.pos + side
            self.minimapMarkers[pn.id].right = pn.pos - side
          end
        end
        -- Add next waypoint position to each waypoint
        for i, wp in ipairs(wps) do
          local nextIndex = (i % #wps) + 1 -- Loop back to 1 at the end
          wp.nextPos = wps[nextIndex].pos
        end
        self.markers.setupMarkers(wps)
      end
      local state = self.pinIn.raceData.value.states[self.pinIn.vehId.value]
      if not state then return end
      local events = state.events
      if not events then return end

      if events.rollingStarted or events.pathnodeReached or events.raceStarted then
        local wps = {}
        for _, m in pairs(self.minimapMarkers) do
          m.mode = 'hidden'
          m.color = modeColors['hidden']
        end
        for _, e in ipairs(state.nextPathnodes) do
          wps[e[1].id] = e[2]
          self.minimapMarkers[e[1].id].mode = e[2]
          self.minimapMarkers[e[1].id].color = modeColors[e[2]] or color(255,255,255,255)
        end
        for _, e in ipairs(state.overNextPathnodes) do
          wps[e[1].id] = 'next'
          self.minimapMarkers[e[1].id].mode = 'next'
          self.minimapMarkers[e[1].id].color = modeColors['next'] or color(255,255,255,255)
        end
        if self.pinIn.alwaysShowFinal.value then
          for _, id in ipairs(self.pinIn.raceData.value.path.config.finalSegments) do
            wps[self.pinIn.raceData.value.path.config.graph[id].targetNode] = 'final'
            self.minimapMarkers[self.pinIn.raceData.value.path.config.graph[id].targetNode].mode = 'final'
            self.minimapMarkers[self.pinIn.raceData.value.path.config.graph[id].targetNode].color = modeColors['final'] or color(255,255,255,255)
          end
        end

        if self.pinIn.ignoreRecovery.value then
          for k, v in pairs(wps) do
            if v == 'recovery' then
              wps[k] = 'default'
              self.minimapMarkers[k].mode = 'default'
              self.minimapMarkers[k].color = modeColors['default'] or color(255,255,255,255)
            end
          end
        end
        --dump(wps)
        self.markers.setModes(wps)
      end
    end
  end
end

--[[
function C:onMinimapRouteOverride(routeOverrides)
  if not self.pinIn.raceData.value then return end
  if not self.route then
    self.route = deepcopy(self.pinIn.raceData.value.path.aiDetailedPath)
    if self.route and self.pinIn.raceData.value.path.config.closed then
      table.insert(self.route, self.route[1])
    end
  end
  if self.route then
    table.insert(routeOverrides, self.route)
  end
end
]]

function C:onDrawOnMinimap(td)
  --if not self.pinIn.raceData.value then return end
  for _, m in pairs(self.minimapMarkers or {}) do
    local clr = m.color
    if m.mode ~= 'hidden' then
      if m.left and m.right then
        ui_apps_minimap_utils.simpleLineWithEdgePointer(m.left, m.right, clr, color(255,255,255,192))
      else
        ui_apps_minimap_utils.simpleCircleWithEdgePointer(m.pos, clr, color(255,255,255,192))
      end
    end
  end
end

function C:onPreRender(dt, dtSim)
  if self.markers then

    self.markers.render(dt, dtSim)
  end
end

function C:_executionStopped()
  if self.markers then
    self.markers.onClientEndMission()
    self.markers = nil
    self.route = {}
  end
end

function C:onClientEndMission()
  self:_executionStopped()
end


function C:destroy()
  self:_executionStopped()
end

return _flowgraph_createNode(C)

