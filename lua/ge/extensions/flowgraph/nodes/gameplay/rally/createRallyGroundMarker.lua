-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = ''

C.name = 'Rally Mode Create Ground Marker Route'
C.description = 'Create a ground marker route.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = {'rally'}
C.category = 'once_instant'
C.pinSchema = {
  { dir = 'in', type = 'table', name = 'pathData', tableType = 'pathData', description = 'Data from the path for other nodes to process.'},
  { dir = 'in', type = 'string', name = 'name', description = 'Name of the position to get; no value will use default.'},
  { dir = 'in', type = 'bool', name = 'includePathnodes', default = true, hidden = true, hardcoded = true, description = 'If true, route through the race pathnodes before the final named position.' },
  { dir = 'in', type = 'number', name = 'routeEndOffsetMeters', default = 10, hidden = true, hardcoded = true, description = 'Moves the visual route endpoint this many meters before the named position along its local -Y axis.' },
}

local minWaypointDistanceSq = 1
local terrainRaycastHeight = 50
local terrainRaycastDistance = 150

local function projectDownToTerrain(pos)
  local projectedPos = vec3(pos)
  if core_terrain then
    local terrainHeight = core_terrain.getTerrainHeight(projectedPos)
    if terrainHeight then
      projectedPos.z = terrainHeight
      return projectedPos
    end
  end

  local rayStart = vec3(projectedPos.x, projectedPos.y, projectedPos.z + terrainRaycastHeight)
  local rayDist = castRayStatic(rayStart, vec3(0, 0, -1), terrainRaycastDistance)
  if rayDist and rayDist < terrainRaycastDistance then
    projectedPos.z = rayStart.z - rayDist
  end
  return projectedPos
end

local function appendWaypoint(wps, pos, replaceLastIfDuplicate)
  if not pos then
    return false
  end

  local wp = vec3(pos)
  local lastWp = wps[#wps]
  if lastWp and wp:squaredDistance(lastWp) <= minWaypointDistanceSq then
    if replaceLastIfDuplicate then
      wps[#wps] = wp
    end
    return false
  end

  table.insert(wps, wp)
  return true
end

local function getVisualRouteEndPos(sp, offsetMeters)
  local stopControlPos = vec3(sp.pos)
  if not offsetMeters or offsetMeters <= 0 or not sp.rot then
    return stopControlPos
  end

  local approachDir = sp.rot * vec3(0, -1, 0)
  approachDir.z = 0
  if approachDir:squaredLength() <= 1e-6 then
    return stopControlPos
  end

  approachDir:normalize()
  return projectDownToTerrain(stopControlPos + approachDir * offsetMeters)
end

local function buildWaypoints(pathData, stopControlPos, includePathnodes)
  local wps = {}

  if includePathnodes and pathData.pathnodes and pathData.pathnodes.sorted then
    for _, pathnode in ipairs(pathData.pathnodes.sorted) do
      appendWaypoint(wps, pathnode.pos)
    end
  end

  appendWaypoint(wps, stopControlPos, true)
  return wps
end

function C:workOnce()
  local pathData = self.pinIn.pathData.value
  if not pathData then
    log('W', logTag, 'cannot create rally ground marker route without pathData')
    return
  end

  local spName = self.pinIn.name.value
  local sp = pathData:findStartPositionByName(spName)
  if not sp then
    log('W', logTag, 'cannot create rally ground marker route; missing start position: ' .. tostring(spName))
    return
  end

  local includePathnodes = self.pinIn.includePathnodes.value ~= false
  local routeEndOffsetMeters = self.pinIn.routeEndOffsetMeters.value or 10
  local visualRouteEndPos = getVisualRouteEndPos(sp, routeEndOffsetMeters)
  local wps = buildWaypoints(pathData, visualRouteEndPos, includePathnodes)
  if #wps == 0 then
    return
  end

  core_groundMarkers.setPath(wps)
  extensions.hook('onCreatedRallyGroundMarkerRoute')
end

return _flowgraph_createNode(C)
