-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local editorUtil = require('/lua/ge/extensions/editor/toolUtilities/util')
local geom = require('editor/toolUtilities/geom')

local M = {}

M.methods = {
  noSnapping = 'no snapping',
  getTerrainHeight = 'getTerrainHeight based snapping',
  vertRaycast = 'vertRaycast based snapping',
}

M.methodValues = {
  M.methods.noSnapping,
  M.methods.getTerrainHeight,
  M.methods.vertRaycast,
}

M.defaultMethod = M.methods.getTerrainHeight

function M.noSnappingInPlace(pos)
  return pos
end

function M.snapTerrainHeightInPlace(pos)
  local terrainHeight = core_terrain and core_terrain.getTerrainHeight and core_terrain.getTerrainHeight(pos) or nil
  if terrainHeight then
    pos.z = terrainHeight
  end
  return pos
end

function M.snapRaycastInPlace(pos, rayRaise)
  editorUtil.vertRaycast(pos, rayRaise)
  return pos
end

local snapInPlaceByMethod = {
  [M.methods.noSnapping] = M.noSnappingInPlace,
  [M.methods.getTerrainHeight] = M.snapTerrainHeightInPlace,
  [M.methods.vertRaycast] = M.snapRaycastInPlace,
}

function M.isValidMethod(method)
  return snapInPlaceByMethod[method] ~= nil
end

function M.snapInPlace(pos, method, rayRaise)
  local snap = snapInPlaceByMethod[method] or snapInPlaceByMethod[M.defaultMethod]
  return snap(pos, rayRaise)
end

function M.zSnap(pos, method, rayRaise)
  return M.snapInPlace(vec3(pos), method, rayRaise)
end

function M.getCurrentMethod()
  local value = editor_rallyEditor and editor_rallyEditor.getPrefWaypointSnapMethod and editor_rallyEditor.getPrefWaypointSnapMethod()
  return M.isValidMethod(value) and value or M.defaultMethod
end

function M.zSnapWithCurrentMethod(pos)
  return M.zSnap(pos, M.getCurrentMethod())
end

function M.snapInPlaceWithCurrentMethod(pos, rayRaise)
  return M.snapInPlace(pos, M.getCurrentMethod(), rayRaise)
end

function M.methodForUseRaycast(useRaycast)
  return useRaycast and M.methods.vertRaycast or M.methods.getTerrainHeight
end

function M.snapDrivelineInPlace(pos, useRaycast, rayRaise)
  return M.snapInPlace(pos, M.methodForUseRaycast(useRaycast), rayRaise)
end

function M.conformSplineGeometry(spline, useRaycast, minNumDivisions, minSpacing, rayRaise)
  if useRaycast then
    return geom.catmullRomRaycast(spline, minNumDivisions, minSpacing, rayRaise)
  end
  return geom.catmullRomConformToTerrain(spline, minNumDivisions, minSpacing, rayRaise)
end

return M
