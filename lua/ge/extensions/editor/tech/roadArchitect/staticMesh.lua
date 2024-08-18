-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Module constants.
local crashBarrierPostSpacing = 2.0                                                                         -- The (fixed) spacing between the crash barrier posts.
local fenceSpacing = 2.0                                                                                    -- The (fixed) spacing between the starts of adjacent fence sections.
local barrierSpacing = 3.0                                                                                  -- The (fixed) spacing between the starts of adjacent concrete barriers.
local latPlateOffset = 0.1                                                                                  -- The (fixed) lateral offset between plate and posts.
local tgtPlateOffset = 1.0                                                                                  -- The (fixed) tangential offset between plate and posts.
local tgtBarrierOffset = 1.5                                                                                -- The (fixed) tangential offset for concrete barriers.
local plateVOffsetUpper = 0.95                                                                              -- The (fixed) vertical offset of the upper crash barrier plates.
local plateVOffsetLower = 0.60                                                                              -- The (fixed) vertical offset of the lower crash barrier plates.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}


-- External modules used.
local profileMgr = require('editor/tech/roadArchitect/profiles')                                            -- Manages the profiles structure/handles profile calculations.

-- Private constants.
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
local random, randomseed = math.random, math.randomseed

-- Module state.
local lampPosts = {}                                                                                        -- The collection of lamp post (static) meshes.
local poleBollards = {}                                                                                     -- The collection of bollard (static) meshes.
local crashPosts = {}                                                                                       -- The collection of crash barrier post (static) meshes.
local crashPlates = {}                                                                                      -- The collection of crash barrier plate sections (static) meshes.
local fences = {}                                                                                           -- The collection mesh fence (static) meshes.
local barriers = {}                                                                                         -- The collection of concrete barrier (static) meshes.

-- Module constants.
local scaleVec = vec3(1, 1, 1)                                                                              -- A vec3 used for representing uniform scale.
local orig = vec3(0, 1, 0)                                                                                  -- The rotation origin vector (vehicle forward in world space).
local origLat1, origLat2 = vec3(1, 0, 0), vec3(-1, 0, 0)                                                    -- The world space lateral vectors.
local tmp1 = vec3(0, 0)                                                                                     -- A temporary vector.
local lampPostPath = 'art/shapes/objects/pole_light_single.dae'                                             -- The (single) lamp post static mesh location.
local lampPostDoublePath = 'art/shapes/objects/pole_light_double.dae'                                       -- The (double) lamp post static mesh location.
local bollardPath = 'art/shapes/objects/bollard_yellow.dae'                                                 -- The bollard static mesh location.
local crashPostPath = 'art/shapes/objects/guardrailpost.dae'                                                -- The crash barrier post mesh location.
local crashPlatePath = 'art/shapes/objects/guardrail1.dae'                                                  -- The crash barrier section mesh location.
local fencePath = 'art/shapes/objects/s_chainlink_old.dae'                                                  -- The mesh fence section mesh location.
local barrierPath = 'art/shapes/objects/jerseybarrier_3m.dae'                                               -- The barrier section mesh location.


-- Computes the length of the given polyline.
local function computePolylineLengths(poly)
  local lens = { 0.0 }
  for i = 2, #poly do
    local iMinus1 = i - 1
    lens[i] = lens[iMinus1] + poly[iMinus1]:distance(poly[i])
  end
  return lens
end

-- Linearly interpolates into a given polyline.
local function polyLerp(pos, rot, lens, q)
  local l, u = 1, #pos
  for i = 2, #lens do
    if lens[i - 1] <= q and lens[i] >= q then
      l, u = i - 1, i
      break
    end
  end
  if q < lens[1] then
    return nil, nil
  end
  if q > lens[#lens] then
    return nil, nil
  end
  local rat = (q - lens[l]) / (lens[u] - lens[l])
  local p = pos[l] + rat * (pos[u] - pos[l])
  local r = rot[l]:nlerp(rot[u], rat)
  return p, r
end

-- Linearly interpolates into a given polyline, including the lateral vector.
local function polyLerpWithLat(pos, rot, lat, lens, q)
  local l, u = 1, #pos
  for i = 2, #lens do
    if lens[i - 1] <= q and lens[i] >= q then
      l, u = i - 1, i
      break
    end
  end
  if q < lens[1] then
    return nil, nil
  end
  if q > lens[#lens] then
    return nil, nil
  end
  local rat = (q - lens[l]) / (lens[u] - lens[l])
  local p = pos[l] + rat * (pos[u] - pos[l])
  local r = rot[l]:nlerp(rot[u], rat)
  local latOut = vec3(0, 0)
  latOut:setLerp(lat[l], lat[u], rat)
  return p, r, latOut
end

-- Creates a row of left-facing lamp posts.
local function createLampPostsL(r, roadIdx, lIdx)
  local rData = r.renderData
  local numDivs = #rData
  randomseed(30000)
  local jitter = r.lampJitter[0]
  local posns, rots = {}, {}
  tmp1:set(0, 0, r.lampPostVertOffset[0])
  for j = 1, numDivs do
    local lData = rData[j][lIdx]
    posns[j] = lData[7] + tmp1
    rots[j] = orig:getRotationTo(-lData[6]:cross(lData[5]))
    rots[j].x = rots[j].x + (random() * 2 - 1) * jitter                                             -- Apply any random jittering, if requested.
    rots[j].y = rots[j].y + (random() * 2 - 1) * jitter
    rots[j].z = rots[j].z + (random() * 2 - 1) * jitter
  end

  -- Create the static meshes for the lamp posts.
  local lens = computePolylineLengths(posns)
  local numLamps = ceil(lens[#lens] / r.lampPostLonSpacing[0])
  lampPosts[r.name] = lampPosts[r.name] or {}
  local q = r.lampPostLonOffset[0] + 1.0
  for j = 1, numLamps do
    local static = createObject('TSStatic')
    static:setField('shapeName', 0, lampPostPath)
    static:setField('decalType', 0, 'None')
    local lampId = 'Lamp post ' .. tostring(roadIdx) .. '-' .. tostring(lIdx) .. '-' .. tostring(j)
    static:registerObject(lampId)
    local pos, rot = polyLerp(posns, rots, lens, q)
    if pos then
      static:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
      static.scale = scaleVec
      static.canSave = true
      scenetree.MissionGroup:addObject(static.obj)
      lampPosts[r.name][lampId] = static
      q = q + r.lampPostLonSpacing[0]
    end
  end
end

-- Creates a row of right-facing lamp posts.
local function createLampPostsR(r, roadIdx, lIdx)
  local rData = r.renderData
  local numDivs = #rData
  randomseed(30000)
  local jitter = r.lampJitter[0]
  local posns, rots = {}, {}
  tmp1:set(0, 0, r.lampPostVertOffset[0])
  for j = 1, numDivs do
    local lData = rData[j][lIdx]
    posns[j] = lData[7] + tmp1
    rots[j] = orig:getRotationTo(lData[6]:cross(lData[5]))
    rots[j].x = rots[j].x + (random() * 2 - 1) * jitter                                             -- Apply any random jittering, if requested.
    rots[j].y = rots[j].y + (random() * 2 - 1) * jitter
    rots[j].z = rots[j].z + (random() * 2 - 1) * jitter
  end

  -- Create the static meshes for the lamp posts.
  local lens = computePolylineLengths(posns)
  local numLamps = ceil(lens[#lens] / r.lampPostLonSpacing[0])
  lampPosts[r.name] = lampPosts[r.name] or {}
  local q = r.lampPostLonOffset[0] + 1.0
  for j = 1, numLamps do
    local static = createObject('TSStatic')
    static:setField('shapeName', 0, lampPostPath)
    static:setField('decalType', 0, 'None')
    local lampId = 'Lamp post ' .. tostring(roadIdx) .. '-' .. tostring(lIdx) .. '-' .. tostring(j)
    static:registerObject(lampId)
    local pos, rot = polyLerp(posns, rots, lens, q)
    if pos then
      static:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
      static.scale = scaleVec
      static.canSave = true
      scenetree.MissionGroup:addObject(static.obj)
      lampPosts[r.name][lampId] = static
      q = q + r.lampPostLonSpacing[0]
    end
  end
end

-- Creates a row of double lamp posts.
local function createLampPostsD(r, roadIdx, lIdx)
  local rData = r.renderData
  local numDivs = #rData
  randomseed(30000)
  local jitter = r.lampJitter[0]
  local posns, rots = {}, {}
  tmp1:set(0, 0, r.lampPostVertOffset[0])
  for j = 1, numDivs do
    local lData = rData[j][lIdx]
    posns[j] = lData[7] + tmp1
    rots[j] = orig:getRotationTo(lData[6]:cross(lData[5]))
    rots[j].x = rots[j].x + (random() * 2 - 1) * jitter                                             -- Apply any random jittering, if requested.
    rots[j].y = rots[j].y + (random() * 2 - 1) * jitter
    rots[j].z = rots[j].z + (random() * 2 - 1) * jitter
  end

  -- Create the static meshes for the lamp posts.
  local lens = computePolylineLengths(posns)
  local numLamps = ceil(lens[#lens] / r.lampPostLonSpacing[0])
  lampPosts[r.name] = lampPosts[r.name] or {}
  local q = r.lampPostLonOffset[0] + 1.0
  for j = 1, numLamps do
    local static = createObject('TSStatic')
    static:setField('shapeName', 0, lampPostDoublePath)
    static:setField('decalType', 0, 'None')
    local lampId = 'Lamp post ' .. tostring(roadIdx) .. '-' .. tostring(lIdx) .. '-' .. tostring(j)
    static:registerObject(lampId)
    local pos, rot = polyLerp(posns, rots, lens, q)
    if pos then
      static:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
      static.scale = scaleVec
      static.canSave = true
      scenetree.MissionGroup:addObject(static.obj)
      lampPosts[r.name][lampId] = static
      q = q + r.lampPostLonSpacing[0]
    end
  end
end

-- Creates a left-side crash barrier.
local function createCrashBarrierL(r, roadIdx, lIdx)
  local rData = r.renderData
  local posns, rots, lats = {}, {}, {}
  tmp1:set(0, 0, r.crashVertOffset[0])
  for j = 1, #rData do
    local lData = rData[j][lIdx]
    local lat = lData[6]
    posns[j] = lData[7] + tmp1
    rots[j] = orig:getRotationTo(-lat)
    lats[j] = lat
  end

  -- Create the static meshes for the crash barrier posts.
  local lens = computePolylineLengths(posns)
  local numPosts = ceil(lens[#lens] / crashBarrierPostSpacing)
  crashPosts[r.name] = crashPosts[r.name] or {}
  local posts = crashPosts[r.name]
  local fPos, fLat, fCtr = {}, {}, 1
  local q = r.crashPostLonOffset[0]
  for j = 1, numPosts do
    local static = createObject('TSStatic')
    static:setField('shapeName', 0, crashPostPath)
    static:setField('decalType', 0, 'None')
    local postId = 'Crash Post ' .. tostring(roadIdx) .. '-' .. tostring(lIdx) .. '-' .. tostring(j)
    static:registerObject(postId)
    local pos, rot, lat = polyLerpWithLat(posns, rots, lats, lens, q)
    if pos then
      static:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
      static.scale = scaleVec
      static.canSave = true
      scenetree.MissionGroup:addObject(static.obj)
      posts[postId] = static
      q = q + crashBarrierPostSpacing
      fPos[fCtr] = pos
      fLat[fCtr] = lat
      fCtr = fCtr + 1
    end
  end

  -- Create the crash barrier plate sections.
  crashPlates[r.name] = crashPlates[r.name] or {}
  local plates = crashPlates[r.name]
  local fNumPosts = #fPos
  for j = 1, fNumPosts - 1 do
    local p1, p2 = fPos[j], fPos[j + 1]
    local v = p2 - p1
    v:normalize()
    local rot = origLat2:getRotationTo(v)
    local latOffset = fLat[j] * latPlateOffset
    local tgtOffset = v * tgtPlateOffset
    p1 = p1 + latOffset + tgtOffset
    local static = createObject('TSStatic')
    static:setField('shapeName', 0, crashPlatePath)
    static:setField('decalType', 0, 'None')
    local plateId = 'Crash Plate A ' .. tostring(roadIdx) .. '-' .. tostring(lIdx) .. '-' .. tostring(j)
    static:registerObject(plateId)
    static:setPosRot(p1.x, p1.y, p1.z + plateVOffsetUpper, rot.x, rot.y, rot.z, rot.w)
    static.scale = scaleVec
    static.canSave = true
    scenetree.MissionGroup:addObject(static.obj)
    plates[plateId] = static
  end
  if r.useDoublePlate[0] then
    for j = 1, fNumPosts - 1 do
      local p1, p2 = fPos[j], fPos[j + 1]
      local v = p2 - p1
      v:normalize()
      local rot = origLat2:getRotationTo(v)
      local latOffset = fLat[j] * latPlateOffset
      local tgtOffset = v * tgtPlateOffset
      p1 = p1 + latOffset + tgtOffset
      local static = createObject('TSStatic')
      static:setField('shapeName', 0, crashPlatePath)
      static:setField('decalType', 0, 'None')
      local plateId = 'Crash Plate B ' .. tostring(roadIdx) .. '-' .. tostring(lIdx) .. '-' .. tostring(j)
      static:registerObject(plateId)
      static:setPosRot(p1.x, p1.y, p1.z + plateVOffsetLower, rot.x, rot.y, rot.z, rot.w)
      static.scale = scaleVec
      static.canSave = true
      scenetree.MissionGroup:addObject(static.obj)
      plates[plateId] = static
    end
  end
end

-- Creates a right-side crash barrier.
local function createCrashBarrierR(r, roadIdx, lIdx)
  local rData = r.renderData
  local posns, rots, lats = {}, {}, {}
  tmp1:set(0, 0, r.crashVertOffset[0])
  for j = 1, #rData do
    local lData = rData[j][lIdx]
    local lat = lData[6]
    posns[j] = lData[7] + tmp1
    rots[j] = orig:getRotationTo(lat)
    lats[j] = lat
  end

  -- Create the static meshes for the crash barrier posts.
  local lens = computePolylineLengths(posns)
  local numPosts = ceil(lens[#lens] / crashBarrierPostSpacing)
  crashPosts[r.name] = crashPosts[r.name] or {}
  local posts = crashPosts[r.name]
  local fPos, fLat, fCtr = {}, {}, 1
  local q = r.crashPostLonOffset[0]
  for j = 1, numPosts do
    local static = createObject('TSStatic')
    static:setField('shapeName', 0, crashPostPath)
    static:setField('decalType', 0, 'None')
    local postId = 'Crash Post ' .. tostring(roadIdx) .. '-' .. tostring(lIdx) .. '-' .. tostring(j)
    static:registerObject(postId)
    local pos, rot, lat = polyLerpWithLat(posns, rots, lats, lens, q)
    if pos then
      static:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
      static.scale = scaleVec
      static.canSave = true
      scenetree.MissionGroup:addObject(static.obj)
      posts[postId] = static
      q = q + crashBarrierPostSpacing
      fPos[fCtr] = pos
      fLat[fCtr] = lat
      fCtr = fCtr + 1
    end
  end

  -- Creates the crash barrier plate sections.
  crashPlates[r.name] = crashPlates[r.name] or {}
  local plates = crashPlates[r.name]
  local fNumPosts = #fPos
  for j = 1, fNumPosts - 1 do
    local p1, p2 = fPos[j], fPos[j + 1]
    local v = p2 - p1
    v:normalize()
    local rot = origLat1:getRotationTo(v)
    local latOffset = -fLat[j] * latPlateOffset
    local tgtOffset = v * tgtPlateOffset
    p1 = p1 + latOffset + tgtOffset
    local static = createObject('TSStatic')
    static:setField('shapeName', 0, crashPlatePath)
    static:setField('decalType', 0, 'None')
    local plateId = 'Crash Plate A ' .. tostring(roadIdx) .. '-' .. tostring(lIdx) .. '-' .. tostring(j)
    static:registerObject(plateId)
    static:setPosRot(p1.x, p1.y, p1.z + plateVOffsetUpper, rot.x, rot.y, rot.z, rot.w)
    static.scale = scaleVec
    static.canSave = true
    scenetree.MissionGroup:addObject(static.obj)
    plates[plateId] = static
  end
  if r.useDoublePlate[0] then
    for j = 1, fNumPosts - 1 do
      local p1, p2 = fPos[j], fPos[j + 1]
      local v = p2 - p1
      v:normalize()
      local rot = origLat1:getRotationTo(v)
      local latOffset = -fLat[j] * latPlateOffset
      local tgtOffset = v * tgtPlateOffset
      p1 = p1 + latOffset + tgtOffset
      local static = createObject('TSStatic')
      static:setField('shapeName', 0, crashPlatePath)
      static:setField('decalType', 0, 'None')
      local plateId = 'Crash Plate B ' .. tostring(roadIdx) .. '-' .. tostring(lIdx) .. '-' .. tostring(j)
      static:registerObject(plateId)
      static:setPosRot(p1.x, p1.y, p1.z + plateVOffsetLower, rot.x, rot.y, rot.z, rot.w)
      static.scale = scaleVec
      static.canSave = true
      scenetree.MissionGroup:addObject(static.obj)
      plates[plateId] = static
    end
  end
end

-- Creates a concrete barrier.
local function createConcreteBarrier(r, roadIdx, lIdx)
  local rData = r.renderData
  local posns, rots, lats = {}, {}, {}
  tmp1:set(0, 0, r.barrierVertOffset[0])
  for j = 1, #rData do
    local lData = rData[j][lIdx]
    local lat = lData[6]
    posns[j] = lData[7] + tmp1
    rots[j] = orig:getRotationTo(-lat)
    lats[j] = lat
  end

  local lens = computePolylineLengths(posns)
  local numPosts = ceil(lens[#lens] / barrierSpacing)
  local fPos, fLat, fCtr = {}, {}, 1
  local q = r.barrierLonOffset[0]
  for j = 1, numPosts do
    local pos, _, lat = polyLerpWithLat(posns, rots, lats, lens, q)
    q = q + barrierSpacing
    fPos[fCtr] = pos
    fLat[fCtr] = lat
    fCtr = fCtr + 1
  end

  barriers[r.name] = barriers[r.name] or {}
  local barrier = barriers[r.name]
  local fNumPosts = #fPos
  for j = 1, fNumPosts - 1 do
    local p1, p2 = fPos[j], fPos[j + 1]
    local v = p2 - p1
    v:normalize()
    local rot = orig:getRotationTo(v)
    local tgtOffset = v * tgtBarrierOffset
    p1 = p1 + tgtOffset
    local static = createObject('TSStatic')
    static:setField('shapeName', 0, barrierPath)
    static:setField('decalType', 0, 'None')
    local plateId = 'Concrete Barrier ' .. tostring(roadIdx) .. '-' .. tostring(lIdx) .. '-' .. tostring(j)
    static:registerObject(plateId)
    static:setPosRot(p1.x, p1.y, p1.z, rot.x, rot.y, rot.z, rot.w)
    static.scale = scaleVec
    static.canSave = true
    scenetree.MissionGroup:addObject(static.obj)
    barrier[plateId] = static
  end
end

-- Creates a row of bollards.
local function createBollards(r, roadIdx, lIdx)
  local rData = r.renderData
  local numDivs = #rData
  randomseed(30000)
  local jitter = r.bollardJitter[0]
  local posns, rots = {}, {}
  tmp1:set(0, 0, r.bollardVertOffset[0])
  for j = 1, numDivs do
    local lData = rData[j][lIdx]
    posns[j] = lData[7] + tmp1
    rots[j] = orig:getRotationTo(lData[6]:cross(lData[5]))
    rots[j].x = rots[j].x + (random() * 2 - 1) * jitter                                             -- Apply any random jittering, if requested.
    rots[j].y = rots[j].y + (random() * 2 - 1) * jitter
    rots[j].z = rots[j].z + (random() * 2 - 1) * jitter
  end

  -- Create the static meshes for the lamp posts.
  local lens = computePolylineLengths(posns)
  local numBollards = ceil(lens[#lens] / r.bollardLonSpacing[0])
  poleBollards[r.name] = poleBollards[r.name] or {}
  local q = r.bollardLonSpacing[0]
  for j = 1, numBollards do
    local static = createObject('TSStatic')
    static:setField('shapeName', 0, bollardPath)
    static:setField('decalType', 0, 'None')
    local bollardId = 'Bollard ' .. tostring(roadIdx) .. '-' .. tostring(lIdx) .. '-' .. tostring(j)
    static:registerObject(bollardId)
    local pos, rot = polyLerp(posns, rots, lens, q)
    if pos then
      static:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
      static.scale = scaleVec
      static.canSave = true
      scenetree.MissionGroup:addObject(static.obj)
      poleBollards[r.name][bollardId] = static
      q = q + r.bollardLonSpacing[0]
    end
  end
end

-- Creates a mesh fence.
local function createFence(r, roadIdx, lIdx)
  local rData = r.renderData
  local posns, rots, lats = {}, {}, {}
  tmp1:set(0, 0, r.fenceVertOffset[0])
  for j = 1, #rData do
    local lData = rData[j][lIdx]
    local lat = lData[6]
    posns[j] = lData[7] + tmp1
    rots[j] = orig:getRotationTo(-lat)
    lats[j] = lat
  end

  local lens = computePolylineLengths(posns)
  local numPosts = ceil(lens[#lens] / fenceSpacing)
  local fPos, fLat, fCtr = {}, {}, 1
  local q = r.fenceLonOffset[0]
  for j = 1, numPosts do
    local pos, _, lat = polyLerpWithLat(posns, rots, lats, lens, q)
    q = q + fenceSpacing
    fPos[fCtr] = pos
    fLat[fCtr] = lat
    fCtr = fCtr + 1
  end

  fences[r.name] = fences[r.name] or {}
  local fence = fences[r.name]
  local fNumPosts = #fPos
  for j = 1, fNumPosts - 1 do
    local p1, p2 = fPos[j], fPos[j + 1]
    local v = p2 - p1
    v:normalize()
    local rot = origLat2:getRotationTo(v)
    local static = createObject('TSStatic')
    static:setField('shapeName', 0, fencePath)
    static:setField('decalType', 0, 'None')
    local plateId = 'Mesh Fence ' .. tostring(roadIdx) .. '-' .. tostring(lIdx) .. '-' .. tostring(j)
    static:registerObject(plateId)
    static:setPosRot(p1.x, p1.y, p1.z, rot.x, rot.y, rot.z, rot.w)
    static.scale = scaleVec
    static.canSave = true
    scenetree.MissionGroup:addObject(static.obj)
    fence[plateId] = static
  end
end

-- Creates all the appropriate static meshes for the given road.
local function createStaticMeshes(r, roadIdx)
  local rData = r.renderData
  for i = -20, 20 do
    local lane = rData[1][i]
    if lane then
      local type = lane[8]
      if type == 'lamp_post_L' then
        createLampPostsL(r, roadIdx, i)
      elseif type == 'lamp_post_R' then
        createLampPostsR(r, roadIdx, i)
      elseif type == 'lamp_post_D' then
        createLampPostsD(r, roadIdx, i)
      elseif type == 'crash_L' then
        createCrashBarrierL(r, roadIdx, i)
      elseif type == 'crash_R' then
        createCrashBarrierR(r, roadIdx, i)
      elseif type == 'concrete' then
        createConcreteBarrier(r, roadIdx, i)
      elseif type == 'bollards' then
        createBollards(r, roadIdx, i)
      elseif type == 'fence' then
        createFence(r, roadIdx, i)
      end
    end
  end
end

-- Attempts to removes the meshes of the road with the given name, from the scene (if it exists).
-- [This is done through road indices; the actual handling of the meshes structure should be private to this module].
local function tryRemove(roadName)

  -- Remove any lamp posts (static meshes), if they exist.
  if lampPosts[roadName] then
    for k, v in pairs(lampPosts[roadName]) do
      v:delete()
    end
  end
  lampPosts[roadName] = nil

  -- Remove any crash barriers (static meshes), if they exist.
  if crashPosts[roadName] then
    for k, v in pairs(crashPosts[roadName]) do
      v:delete()
    end
  end
  if crashPlates[roadName] then
    for k, v in pairs(crashPlates[roadName]) do
      v:delete()
    end
  end
  crashPosts[roadName] = nil
  crashPlates[roadName] = nil

  -- Remove any concrete barriers (static meshes), if they exist.
  if barriers[roadName] then
    for k, v in pairs(barriers[roadName]) do
      v:delete()
    end
  end
  barriers[roadName] = nil

  -- Remove any bollards (static meshes), if they exist.
  if poleBollards[roadName] then
    for k, v in pairs(poleBollards[roadName]) do
      v:delete()
    end
  end
  poleBollards[roadName] = nil

  -- Remove any mesh fences (static meshes), if they exist.
  if fences[roadName] then
    for k, v in pairs(fences[roadName]) do
      v:delete()
    end
  end
  fences[roadName] = nil
end


-- Public interface.
M.createStaticMeshes =                                    createStaticMeshes
M.tryRemove =                                             tryRemove

return M