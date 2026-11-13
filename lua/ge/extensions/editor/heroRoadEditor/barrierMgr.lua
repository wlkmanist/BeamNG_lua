-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Roadside furniture (barriers + fences + lamp posts) for a Hero Road group.

local M = {}

-- Module dependencies.
local props = require('editor/toolUtilities/roadsideProps')

-- Module constants.
local min, max, sqrt = math.min, math.max, math.sqrt
local barrierSinkM = { guardrail = -0.35, jersey = 0.0, plastic = -0.15 }

-- Module state.
local railPts, railUps = {}, {} -- reused rail scratch (world points + per-point up).
local segS = {} -- reused arc-length scratch for mapping a placeable barrier's length window onto edge station indices.
local barrierKeysById = {} -- id -> array of barrier pool keys currently placed (whole-road pair + one per placeable segment).


-- Builds a per-side rail (edge pushed outward by offsetM along the banked lateral).
local function runSide(folder, edge, dir, up, offsetM, presetKey, poolKey, sideSign, stepM, lockEnds, isLoop, i0, i1, vertM)
  local n = edge and #edge or 0
  i0 = i0 or 1
  i1 = i1 or n
  local count = i1 - i0 + 1
  if count < 2 or not dir then props.removePool(poolKey); return end
  local vz = vertM or 0.0
  local w = 0
  for i = i0, i1 do
    local p, d = edge[i], dir[i]
    w = w + 1
    railPts[w] = railPts[w] or vec3()
    railPts[w]:set(p.x + d.x * offsetM, p.y + d.y * offsetM, p.z + d.z * offsetM + vz)
    railUps[w] = (up and up[i]) or nil
  end
  for i = w + 1, #railPts do railPts[i], railUps[i] = nil, nil end
  props.runLine({ poolId = poolKey, folder = folder, presetKey = presetKey, railPts = railPts, railUps = railUps, sideSign = sideSign, stepM = stepM, lockEnds = lockEnds, isLoop = isLoop })
end

-- Drops every barrier pool tracked for this group id (whole-road pair or the variable set of corner segments) and resets the
-- registry. Fences/lamps have their own fixed keys and are handled separately.
local function clearBarrierPools(id)
  local keys = barrierKeysById[id]
  if keys then
    for i = 1, #keys do props.removePool(keys[i]) end
  end
  barrierKeysById[id] = {}
end

-- Maps a placeable barrier's arc-length window (centre t01, length lengthM) onto a contiguous [i0..i1] station range on the
-- given edge. Returns nil when the edge is too short. Arc length is measured along the edge itself (into the reused segS).
local function segRange(edge, t01, lengthM)
  local n = edge and #edge or 0
  if n < 2 then return nil end
  segS[1] = 0.0
  for i = 2, n do
    local a, b = edge[i - 1], edge[i]
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    segS[i] = segS[i - 1] + sqrt(dx * dx + dy * dy + dz * dz)
  end
  local total = segS[n]
  if total <= 1e-6 then return nil end
  local half = max(0.25, (lengthM or 1.0) * 0.5)
  local c = min(max(t01 or 0.5, 0.0), 1.0) * total
  local lo, hi = c - half, c + half
  local i0, i1
  for i = 1, n do if segS[i] >= lo then i0 = i; break end end
  for i = n, 1, -1 do if segS[i] <= hi then i1 = i; break end end
  i0 = i0 or 1
  i1 = i1 or n
  if i1 - i0 < 1 then i0 = max(1, min(i0, n - 1)); i1 = min(n, i0 + 1) end -- always at least one segment.
  return i0, i1
end

-- (Re)builds the group's barriers to match the current mesh edge + selections. Two independent sources:
--   * Furniture tab: whole-road rails per side (group.barrierLeftType / barrierRightType).
--   * Features tab: placeable barrier segments (group.barriers), each a run of one type on one side over a length window.
local function updateBarriers(group, folder, eL, eR, dL, dR, up, bOff)
  local id = group.id
  clearBarrierPools(id)
  local keys = barrierKeysById[id]

  -- Whole-road rails (Furniture tab): one per side, full length, seated by the type's standard burial.
  local lType, rType = group.barrierLeftType or 'none', group.barrierRightType or 'none'
  runSide(folder, eL, dL, up, bOff, lType, id .. 'bL', -1, nil, false, false, nil, nil, barrierSinkM[lType] or 0.0); keys[#keys + 1] = id .. 'bL'
  runSide(folder, eR, dR, up, bOff, rType, id .. 'bR', 1, nil, false, false, nil, nil, barrierSinkM[rType] or 0.0); keys[#keys + 1] = id .. 'bR'

  -- Placeable segments (Features tab): each rides its own side's edge over its length window, at its own offset + type. The
  -- vertical seat is the type's standard burial plus this segment's extra zOffsetM tweak.
  local barriers = group.barriers
  for b = 1, (barriers and #barriers or 0) do
    local seg = barriers[b]
    local bType = seg.type or 'guardrail'
    if bType ~= 'none' then
      local left = seg.side == 'left'
      local edge, dir, sign = left and eL or eR, left and dL or dR, left and -1 or 1
      local i0, i1 = segRange(edge, seg.t or 0.5, seg.lengthM)
      if i0 then
        local key = id .. 'bP' .. b
        local vert = (barrierSinkM[bType] or 0.0) + (seg.zOffsetM or 0.0)
        runSide(folder, edge, dir, up, seg.offsetM or bOff, bType, key, sign, nil, false, false, i0, i1, vert)
        keys[#keys + 1] = key
      end
    end
  end
end

-- (Re)builds the group's barriers + fences + lamp posts to match the current mesh edge + selections. Called after the mesh rebuild.
local function updateGroup(group)
  if not group or not group.id then return end
  local folder = group.sceneTreeFolderId and scenetree.findObjectById(group.sceneTreeFolderId)
  if not folder then return end
  local id = group.id
  local eL, eR, dL, dR, up = group.meshEdgeL, group.meshEdgeR, group.meshEdgeDirL, group.meshEdgeDirR, group.meshEdgeUp
  local bOff = group.barrierOffsetM or 0.5
  local fOff = group.fenceOffsetM or 0.7
  local lOff = group.lampOffsetM or 1.0
  local lStep = group.lampSpacingM

  updateBarriers(group, folder, eL, eR, dL, dR, up, bOff)
  runSide(folder, eL, dL, up, fOff, group.fenceLeftType or 'none', id .. 'fL', -1)
  runSide(folder, eR, dR, up, fOff, group.fenceRightType or 'none', id .. 'fR', 1)
  -- Lamps end-anchor like bridgeSpline: a post pinned at both the start and end, the interior even-fit toward the spacing slider.
  runSide(folder, eL, dL, up, lOff, group.lampLeftType or 'none', id .. 'lL', -1, lStep, true, group.isLoop)
  runSide(folder, eR, dR, up, lOff, group.lampRightType or 'none', id .. 'lR', 1, lStep, true, group.isLoop)
end

-- Deletes all placed furniture for the group (teardown / node count dropped below 2).
local function removeGroup(group)
  if not group or not group.id then return end
  local id = group.id
  clearBarrierPools(id)
  props.removePool(id .. 'fL'); props.removePool(id .. 'fR')
  props.removePool(id .. 'lL'); props.removePool(id .. 'lR')
end

-- The fixed (non-barrier) furniture pool keys for a group (fences / lamps, per side).
local function fenceLampKeys(id)
  return { id .. 'fL', id .. 'fR', id .. 'lL', id .. 'lR' }
end

-- Live placed-piece counts for a group, by category (both sides summed). Reads the transient prop pools -- so it reflects the
-- editable preview; a baked road's furniture is committed out of the pools, so this reports 0 there (as intended -- baked = locked).
local function counts(group)
  if not group or not group.id then return 0, 0, 0 end
  local id = group.id
  local barriers = 0
  local keys = barrierKeysById[id]
  if keys then for i = 1, #keys do barriers = barriers + props.poolCount(keys[i]) end end
  local fences   = props.poolCount(id .. 'fL') + props.poolCount(id .. 'fR')
  local lamps    = props.poolCount(id .. 'lL') + props.poolCount(id .. 'lR')
  return barriers, fences, lamps
end

-- Burn: flip the group's current furniture pieces to persistent (canSave=true) and detach them from the transient pools
-- (props.commitPool). Returns the merged name manifest; the caller (exportMgr bake) stores it.
local function burnGroup(group)
  local uids = {}
  if not group or not group.id then return uids end
  local id = group.id
  local keys = {}
  local bKeys = barrierKeysById[id]
  if bKeys then for i = 1, #bKeys do keys[#keys + 1] = bKeys[i] end end
  for _, k in ipairs(fenceLampKeys(id)) do keys[#keys + 1] = k end
  for _, key in ipairs(keys) do
    local u = props.commitPool(key)
    for i = 1, #u do uids[#uids + 1] = u[i] end
  end
  barrierKeysById[id] = {} -- committed out of the pools; drop the registry so a later rebuild starts clean.
  return uids
end


-- Public interface.
M.updateGroup = updateGroup
M.counts = counts
M.removeGroup = removeGroup
M.burnGroup = burnGroup

return M