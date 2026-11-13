--[[
This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
If a copy of the bCDDL was not distributed with this
file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
This module contains a set of functions which manipulate behaviours of vehicles.
]]

local M = {}

local stringBuffer = require('string.buffer')

local byte = string.byte
local t_insert, t_clear, t_sort = table.insert, table.clear, table.sort
local rad, deg, min, max = math.rad, math.deg, math.min, math.max
local sin, cos, sqrt, atan2 = math.sin, math.cos, math.sqrt, math.atan2

M.ignoreSections = {maxIDs=true, options=true}

-- these are defined in C, do not change the values
local NORMALTYPE = 0
local BEAM_LBEAM = 4

local function increaseMax(vehicle, name)
  local res = vehicle.maxIDs[name] or 0
  vehicle.maxIDs[name] = res + 1
  return res
end

local function addNodeWithOptions(vehicle, pos, ntype, options)
  local n
  if type(options) == 'table' then
    n = deepcopy(options)
  else
    n = {}
  end

  local nextID = increaseMax(vehicle, 'nodes')
  n.cid     = nextID
  n.pos     = pos
  n.ntype   = ntype

  --log('D', "jbeam.addNodeWithOptions","adding node "..(nextID)..".")
  t_insert(vehicle.nodes, n)
  return nextID
end

local function addNode(vehicle, pos, ntype)
  return addNodeWithOptions(vehicle, pos, ntype, vehicle.options)
end

local function addBeamWithOptions(vehicle, id1, id2, beamType, options, id3)
  id1 = id1 or options.id1
  id2 = id2 or options.id2

  -- check if nodes are valid
  local node1 = vehicle.nodes[id1]
  local node2 = vehicle.nodes[id2]
  if node1 == nil or node2 == nil then
    if node1 == nil then
      log('W', "jbeam.addBeamWithOptions","invalid node "..tostring(id1).." for new beam between "..tostring(id1).."->"..tostring(id2))
      return
    end
    if node2 == nil then
      log('W', "jbeam.addBeamWithOptions","invalid node "..tostring(id2).." for new beam between "..tostring(id1).."->"..tostring(id2))
      return
    end
  end

  -- increase counters
  local nextID = increaseMax(vehicle, 'beams')

  local b
  if type(options) == 'table' then
    b = deepcopy(options)
  else
    b = {}
  end

  if id3 ~= nil then
    local node3 = vehicle.nodes[id3]
    if node3 == nil then
      log('W', "jbeam.addBeamWithOptions","invalid node "..tostring(id3).." for new beam between "..tostring(id1).."->"..tostring(id2))
      return
    else
      beamType = BEAM_LBEAM
    end
    b.id3 = node3.cid
  end

  b.cid      = nextID
  b.id1      = node1.cid
  b.id2      = node2.cid
  b.beamType = beamType

  -- add the beam
  t_insert(vehicle.beams, b)
  return b
end

local function addBeam(vehicle, id1, id2)
  return addBeamWithOptions(vehicle, id1, id2, NORMALTYPE, vehicle.options)
end

local function addRotator(vehicle, wheelKey, wheel)
  wheel.frictionCoef = wheel.frictionCoef or 1

  local nodes = {}
  if wheel._group_nodes ~= nil then
    for k, v in ipairs(wheel._group_nodes) do
      t_insert(nodes, vehicle.nodes[v])
    end
  end

  if wheel._rotatorGroup_nodes ~= nil then
    for k, v in ipairs(wheel._rotatorGroup_nodes) do
      t_insert(nodes, vehicle.nodes[v])
    end
  end

  if next(nodes) ~= nil then
    wheel.nodes = nodes
  end
end

local cacheNodeRots, cacheNodeOffsets, cacheNodeMoves, cachePosXSign, cacheOpCount = {}, {}, {}, 0, 0
local cacheRot, cacheHasRot, cachePosX, cachePosY, cachePosZ = quat(0, 0, 0, 1), false, 0, 0, 0
local nodeRots, nodeOffsets, nodeMoves, opMin, opMax, opCount = {}, {}, {}, math.huge, -math.huge, 0
local tmpQuat1, tmpQuat2 = quat(0, 0, 0, 1), quat(0, 0, 0, 1)
local tmpVec1 = vec3()

-- radians, same euler parametrization as MatrixF (ZXY intrinsic)
local function setQuatFromEuler(q, x, y, z)
  x, y, z = x * 0.5, y * 0.5, z * 0.5
  local sx, cx, sy, cy, sz, cz = sin(x), cos(x), sin(y), cos(y), sin(z), cos(z)
  q:set(cz*sx*cy - sz*cx*sy, cz*cx*sy + sz*sx*cy, sz*cx*cy + cz*sx*sy, cz*cx*cy - sz*sx*sy)
end

local function quatToEuler(q)
  local x, y, z, w = q.x, q.y, q.z, q.w
  local xx, yy, zz, ww = x*x, y*y, z*z, w*w
  local cxsy, cxcy = 2 * (w*y - x*z), ww - xx - yy + zz
  local cx = sqrt(cxsy*cxsy + cxcy*cxcy)
  local ex = atan2(2 * (y*z + w*x), cx)
  if cx < 1e-7 then -- gimbal lock
    return ex, 0, atan2(2 * (x*y + w*z), ww + xx - yy - zz)
  end
  return ex, atan2(cxsy, cxcy), atan2(2 * (w*z - x*y), ww - xx + yy - zz)
end

local function getNodeRotOffsetMoves(jbeamData)
  table.clear(nodeRots)
  table.clear(nodeOffsets)
  table.clear(nodeMoves)
  opMin, opMax, opCount = math.huge, -math.huge, 0

  for nodeKey, data in pairs(jbeamData) do
    if type(nodeKey) == 'string' and type(data) == 'table' and type(data.x) == 'number' and type(data.y) == 'number' and type(data.z) == 'number'
    and byte(nodeKey,4) == 101 and byte(nodeKey,3) == 100 and byte(nodeKey,2) == 111 and byte(nodeKey,1) == 110 then
      -- check for "nodeRotate##"
      if byte(nodeKey,10)==101 and byte(nodeKey,9)==116 and byte(nodeKey,8)==97 and byte(nodeKey,7)==116 and byte(nodeKey,6)==111 and byte(nodeKey,5)==82 then
        local idx1, idx2 = byte(nodeKey,11), byte(nodeKey,12)
        idx1 = idx1 ~= nil and idx1 - 48 or 0
        if idx2 ~= nil then idx1 = idx1 * 10 + idx2 - 48 end
        nodeRots[idx1] = data
        opMin, opMax, opCount = min(opMin, idx1), max(opMax, idx1), opCount + 1

      -- check for "nodeOffset##", ignoring offset if jbeamData.ignoreNodeOffset
      elseif not jbeamData.ignoreNodeOffset and byte(nodeKey,10)==116 and byte(nodeKey,9)==101 and byte(nodeKey,8)==115 and byte(nodeKey,7)==102 and byte(nodeKey,6)==102 and byte(nodeKey,5)==79 then
        local idx1, idx2 = byte(nodeKey,11), byte(nodeKey,12)
        idx1 = idx1 ~= nil and idx1 - 48 or 0
        if idx2 ~= nil then idx1 = idx1 * 10 + idx2 - 48 end
        nodeOffsets[idx1] = data
        opMin, opMax, opCount = min(opMin, idx1), max(opMax, idx1), opCount + 1

      -- check for "nodeMove##"
      elseif byte(nodeKey,8)==101 and byte(nodeKey,7)==118 and byte(nodeKey,6)==111 and byte(nodeKey,5)==77 then
        local idx1, idx2 = byte(nodeKey,9), byte(nodeKey,10)
        idx1 = idx1 ~= nil and idx1 - 48 or 0
        if idx2 ~= nil then idx1 = idx1 * 10 + idx2 - 48 end
        nodeMoves[idx1] = data
        opMin, opMax, opCount = min(opMin, idx1), max(opMax, idx1), opCount + 1
      end
    end
  end
end

local function updateNodeTransformCache(posX)
  local useCache = true

  if opCount ~= cacheOpCount then
    useCache = false
  else
    for i = opMin, opMax do
      local cacheNodeRot, nodeRot = cacheNodeRots[i], nodeRots[i]
      if cacheNodeRot or nodeRot then
        if (not cacheNodeRot and nodeRot or cacheNodeRot and not nodeRot) or cacheNodeRot.x ~= nodeRot.x or cacheNodeRot.y ~= nodeRot.y or cacheNodeRot.z ~= nodeRot.z
        or cacheNodeRot.px ~= nodeRot.px or cacheNodeRot.py ~= nodeRot.py or cacheNodeRot.pz ~= nodeRot.pz then
          useCache = false
          break
        end
      end
      local cacheNodeOffset, nodeOffset = cacheNodeOffsets[i], nodeOffsets[i]
      if cacheNodeOffset or nodeOffset then
        if (not cacheNodeOffset and nodeOffset or cacheNodeOffset and not nodeOffset) or cachePosXSign ~= sign(posX) or cacheNodeOffset.x ~= nodeOffset.x or cacheNodeOffset.y ~= nodeOffset.y or cacheNodeOffset.z ~= nodeOffset.z then
          useCache = false
          break
        end
      end
      local cacheNodeMove, nodeMove = cacheNodeMoves[i], nodeMoves[i]
      if cacheNodeMove or nodeMove then
        if (not cacheNodeMove and nodeMove or cacheNodeMove and not nodeMove) or cacheNodeMove.x ~= nodeMove.x or cacheNodeMove.y ~= nodeMove.y or cacheNodeMove.z ~= nodeMove.z then
          useCache = false
          break
        end
      end
    end
  end

  if useCache then return end

  table.clear(cacheNodeRots)
  table.clear(cacheNodeOffsets)
  table.clear(cacheNodeMoves)
  cachePosXSign, cacheOpCount = sign(posX), opCount
  cacheHasRot = next(nodeRots) ~= nil
  cacheRot:set(0, 0, 0, 1)
  cachePosX, cachePosY, cachePosZ = 0, 0, 0

  for i = opMin, opMax do
    -- First apply rotation (if any)
    if nodeRots[i] then
      local op = nodeRots[i]
      local px = type(op.px) == 'number' and op.px or 0
      local py = type(op.py) == 'number' and op.py or 0
      local pz = type(op.pz) == 'number' and op.pz or 0

      setQuatFromEuler(tmpQuat1, rad(-op.x), rad(-op.y), rad(-op.z))
      tmpVec1:set(px, py, pz)
      tmpVec1:setRotate(tmpQuat1)
      tmpVec1:set(px - tmpVec1.x, py - tmpVec1.y, pz - tmpVec1.z)
      tmpVec1:setRotate(cacheRot)
      cachePosX, cachePosY, cachePosZ = cachePosX + tmpVec1.x, cachePosY + tmpVec1.y, cachePosZ + tmpVec1.z
      cacheRot:setMul2(tmpQuat1, cacheRot)
      cacheNodeRots[i] = nodeRots[i]
    end

    -- Then apply offset (if any)
    if nodeOffsets[i] then
      local op = nodeOffsets[i]
      tmpVec1:set(cachePosXSign * op.x, op.y, op.z)
      tmpVec1:setRotate(cacheRot)
      cachePosX, cachePosY, cachePosZ = cachePosX + tmpVec1.x, cachePosY + tmpVec1.y, cachePosZ + tmpVec1.z
      cacheNodeOffsets[i] = nodeOffsets[i]
    end

    -- Finally apply move (if any)
    if nodeMoves[i] then
      local op = nodeMoves[i]
      tmpVec1:set(op.x, op.y, op.z)
      tmpVec1:setRotate(cacheRot)
      cachePosX, cachePosY, cachePosZ = cachePosX + tmpVec1.x, cachePosY + tmpVec1.y, cachePosZ + tmpVec1.z
      cacheNodeMoves[i] = nodeMoves[i]
    end
  end
end

local function getPosAfterNodeRotateOffsetMove(jbeamData, x, y, z)
  getNodeRotOffsetMoves(jbeamData)
  if opCount == 0 then return x, y, z end

  updateNodeTransformCache(x)

  if cacheHasRot then
    tmpVec1:set(x, y, z)
    tmpVec1:setRotate(cacheRot)
    x, y, z = tmpVec1:xyz()
  end
  return x + cachePosX, y + cachePosY, z + cachePosZ
end

local function getFlexbodyPosRotAfterNodeRotateOffsetMove(jbeamData, x, y, z, rx, ry, rz)
  getNodeRotOffsetMoves(jbeamData)
  if opCount == 0 then return end

  updateNodeTransformCache(x)

  if cacheHasRot then
    tmpVec1:set(x, y, z)
    tmpVec1:setRotate(cacheRot)
    setQuatFromEuler(tmpQuat1, rad(-rx), rad(-ry), rad(-rz))
    tmpQuat1:setMul2(cacheRot, tmpQuat1)
    local ex, ey, ez = quatToEuler(tmpQuat1)
    return tmpVec1.x + cachePosX, tmpVec1.y + cachePosY, tmpVec1.z + cachePosZ, deg(-ex), deg(-ey), deg(-ez)
  else
    return x + cachePosX, y + cachePosY, z + cachePosZ
  end
end

--
local function getPosRotBeforeNodeRotateOffsetMove(jbeamData, x, y, z, rx, ry, rz)
  getNodeRotOffsetMoves(jbeamData)

  if opCount == 0 then
    return x, y, z, rx, ry, rz
  end

  local function calculatePosRot(posXSign)
    updateNodeTransformCache(posXSign)

    if cacheHasRot then
      tmpQuat1:set(cacheRot)
      tmpQuat1:inverse()
      tmpVec1:set(x - cachePosX, y - cachePosY, z - cachePosZ)
      tmpVec1:setRotate(tmpQuat1)
      setQuatFromEuler(tmpQuat2, rad(-rx), rad(-ry), rad(-rz))
      tmpQuat2:setMul2(tmpQuat1, tmpQuat2)
      local ex, ey, ez = quatToEuler(tmpQuat2)
      return tmpVec1.x, tmpVec1.y, tmpVec1.z, deg(-ex), deg(-ey), deg(-ez)
    else
      return x - cachePosX, y - cachePosY, z - cachePosZ, rx, ry, rz
    end
  end

  local outX, outY, outZ, outRx, outRy, outRz = calculatePosRot(1)
  if sign(outX) == 1 then
    return outX, outY, outZ, outRx, outRy, outRz
  end

  outX, outY, outZ, outRx, outRy, outRz = calculatePosRot(0)
  if sign(outX) == 0 then
    return outX, outY, outZ, outRx, outRy, outRz
  end

  return calculatePosRot(-1)
end

local function stringBufferEncode(data)
  local buf = stringBuffer.new()
  buf:encode(data)
  return buf
end

local function stringBufferDecode(buf)
  return buf:peekdecode()
end

M.addNodeWithOptions = addNodeWithOptions
M.addNode = addNode
M.increaseMax = increaseMax
M.addBeamWithOptions = addBeamWithOptions
M.addBeam = addBeam
M.addRotator = addRotator
M.getPosAfterNodeRotateOffsetMove = getPosAfterNodeRotateOffsetMove
M.getFlexbodyPosRotAfterNodeRotateOffsetMove = getFlexbodyPosRotAfterNodeRotateOffsetMove
M.getPosRotBeforeNodeRotateOffsetMove = getPosRotBeforeNodeRotateOffsetMove
M.stringBufferEncode = stringBufferEncode
M.stringBufferDecode = stringBufferDecode

return M