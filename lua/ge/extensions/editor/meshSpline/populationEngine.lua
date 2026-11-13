-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local geom = require("editor/toolUtilities/geom")
local util = require("editor/toolUtilities/util")

local function clearDerivedGeometry(spline)
  table.clear(spline.divPoints)
  table.clear(spline.divWidths)
  table.clear(spline.tangents)
  table.clear(spline.binormals)
  table.clear(spline.normals)
  table.clear(spline.discMap)
end

function M.updateGeometry(spline, minimumDivisions)
  if not spline or not spline.nodes or #spline.nodes < 2 then
    if spline then clearDerivedGeometry(spline) end
    return false
  end

  if spline.isConformToTerrain then
    local terrain = spline.terrainOnly and core_terrain.getTerrain() or nil
    if terrain then
      for _, node in ipairs(spline.nodes) do
        node.z = terrain:getHeight(node) + (spline.rayPostFloat or 0)
      end
      geom.catmullRomConformToTerrain(spline, minimumDivisions)
    else
      for _, node in ipairs(spline.nodes) do
        util.vertRaycast(node, nil, spline.rayPostFloat)
      end
      geom.catmullRomRaycast(spline, minimumDivisions)
    end
  else
    geom.catmullRomFree(spline, minimumDivisions)
  end
  return #spline.divPoints >= 2
end

-- When `useEvenFit` is true, `spacing` is treated as a TARGET: an item is locked to both ends and the interior is spaced
-- as evenly as possible near that target (see geom.sampleSplineEvenFit). Otherwise it's the usual fixed-period walk.
function M.sample(spline, spacing, outPositions, outTangents, outNormals, useEvenFit)
  if not spline or not spline.divPoints or #spline.divPoints < 2 then
    table.clear(outPositions)
    table.clear(outTangents)
    table.clear(outNormals)
    return outPositions, outTangents, outNormals
  end
  if useEvenFit then
    geom.sampleSplineEvenFit(
      spline.divPoints,
      spline.tangents,
      spline.normals,
      spacing,
      spline.isLoop,
      outPositions,
      outTangents,
      outNormals)
    return outPositions, outTangents, outNormals
  end
  return geom.sampleSpline(
    spline.divPoints,
    spline.tangents,
    spline.normals,
    spacing,
    outPositions,
    outTangents,
    outNormals)
end

function M.intervalFrame(
  positions,
  tangents,
  normals,
  index,
  outPosition,
  outTangent,
  outUp,
  previousAcross)
  if not positions[index] or not positions[index + 1] then return false end
  geom.ribbonIntervalFrame(
    positions[index],
    positions[index + 1],
    tangents[index],
    tangents[index + 1],
    normals[index],
    normals[index + 1],
    outPosition,
    outTangent,
    outUp,
    previousAcross)
  return true
end

M.clearDerivedGeometry = clearDerivedGeometry

return M
