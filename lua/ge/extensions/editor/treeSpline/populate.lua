-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = 'treeSpline.populate'

-- External modules.
local scatter = require('editor/toolUtilities/foliageScatter')
local occupancy = require('editor/toolUtilities/occupancy')


-- Resolves the level's Forest data (does not create one; ensureForest handles creation on scatter).
local function getForestData()
  local forest = core_forest.getForestObject()
  return forest and forest:getData() or nil
end

-- Removes the forest instances previously planted for this spline.
local function tryRemove(spline)
  if not spline or not spline.items then return end
  local fd = getForestData()
  if fd then scatter.removeItems(fd, spline.items) end
  spline.items = {}
  spline.count = 0
end

-- (Re)plants the spline: clears its previous instances, then scatters a fresh evenly-spaced row along the
-- current centreline from the spline's foliage params.
local function populateTreeSpline(spline)
  if not spline then return end
  local _, fd = scatter.ensureForest()
  if not fd then log('W', logTag, 'No Forest data available; cannot plant tree spline.'); return end

  scatter.removeItems(fd, spline.items)

  if not spline.divPoints or #spline.divPoints < 2 then
    spline.items, spline.count = {}, 0
    return
  end

  -- Keep-out is a passive query: if nothing has been stamped (bare level / hand-drawn use) occupiedAt returns
  -- false, so this is a no-op unless an importer built the mask.
  local occupiedFn = spline.avoidInfrastructure and occupancy.occupiedAt or nil
  local items, count = scatter.scatterLine({
    divPoints = spline.divPoints,
    binormals = spline.binormals,
    species = spline.species,
    speciesWeights = spline.speciesWeights,
    spacingM = spline.spacingM,
    posVariance = spline.posVariance,
    scaleVariance = spline.scaleVariance,
    alignToNormal = spline.alignToNormal,
    slopeMaxDeg = spline.slopeMaxDeg,
    seed = spline.seed,
    forestData = fd,
    occupiedFn = occupiedFn,
  })
  spline.items = items
  spline.count = count or 0
end


-- Lua reload: the tool lets go of a locked spline's trees without removing them (they are the level's) and returns their keys
-- and positions, for adopt() to find again.
local function release(spline)
  local kept = {}
  for _, it in ipairs(spline.items or {}) do
    local p = it:getPosition()
    kept[#kept + 1] = { it:getKey(), p.x, p.y, p.z }
  end
  spline.items, spline.count = {}, 0
  return kept
end

-- Takes back the trees release() let go of (those still in the forest), as they are.
local function adopt(spline, kept)
  local fd = getForestData()
  if not fd then return end
  local items = {}
  for _, k in ipairs(kept) do
    local it = fd:getItem(k[1], vec3(k[2], k[3], k[4]))
    if it and it:getKey() ~= 0 then items[#items + 1] = it end
  end
  spline.items, spline.count = items, #items
end


-- Public interface.
M.tryRemove = tryRemove
M.populateTreeSpline = populateTreeSpline
M.release = release
M.adopt = adopt

return M