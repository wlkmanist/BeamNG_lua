-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This file defines common library functions that are useful only in vehicle Lua.

local M = {}

local function computeMassProperties(withoutWheels)
  -- Compute vehicle's total mass, COG and inertia (about COG) in world coordinates
  local totalMass = 0
  local cogWeighted = vec3(0, 0, 0)
  local inertiaX = 0
  local inertiaY = 0
  local inertiaZ = 0
  local inertiaXY = 0
  local inertiaXZ = 0
  local inertiaYZ = 0
  local withWheels = not withoutWheels
  for _, n in pairs(v.data.nodes) do
    local cid = n.cid
    local r = obj:getAbsNodePosition(cid)
    local m = obj:getNodeMass(cid)
    local isWheelNode = n.wheelID ~= nil
    if withWheels or (not isWheelNode) then
      totalMass = totalMass + m
      cogWeighted = cogWeighted + m * r
      inertiaX = inertiaX + m * (r.y * r.y + r.z * r.z)
      inertiaY = inertiaY + m * (r.x * r.x + r.z * r.z)
      inertiaZ = inertiaZ + m * (r.x * r.x + r.y * r.y)
      inertiaXY = inertiaXY - m * (r.x * r.y)
      inertiaXZ = inertiaXZ - m * (r.x * r.z)
      inertiaYZ = inertiaYZ - m * (r.y * r.z)
    end
  end
  local cog = cogWeighted / totalMass
  return {
    mass = totalMass,
    center_of_gravity = {cog.x, cog.y, cog.z},
    -- compute inertia about to center of mass
    inertia = {
      x = inertiaX - totalMass * (cog.y * cog.y + cog.z * cog.z),
      y = inertiaY - totalMass * (cog.x * cog.x + cog.z * cog.z),
      z = inertiaZ - totalMass * (cog.x * cog.x + cog.y * cog.y),
      xy = inertiaXY + totalMass * (cog.x * cog.y),
      xz = inertiaXZ + totalMass * (cog.x * cog.z),
      yz = inertiaYZ + totalMass * (cog.y * cog.z),
    },
  }
end

local function getRefNodes()
  -- Get a table of vehicle ref nodes
  local refNodeIds = v.data.refNodes[0]
  local properties = {'ref', 'left', 'back', 'up', 'leftCorner', 'rightCorner'}
  local refNodes = {}
  for _, k in ipairs(properties) do
    local cid = refNodeIds[k]
    local node = v.data.nodes[cid]
    assert(node and node.cid == cid)
    refNodes[k] = node.name
  end
  return refNodes
end

local function getNodeCache()
  -- Create a cache of vehicle nodes, useful for lookup CID values by node name
  local nameToCid = {}
  local cidList = {}
  for _, n in pairs(v.data.nodes) do
    if n.name then
      nameToCid[n.name] = n.cid
    end
    table.insert(cidList, n.cid)
  end
  local nodeCache = {
    nameToCid = nameToCid,
    cidList = cidList,
  }
  return nodeCache
end

local function getNodeInfo(nodeCache, requestedNodesList)
  -- Query information (name, cid, mass, position) about vehicle nodes
  local requestedNodes = requestedNodesList or nodeCache.cidList
  local nodes = {}
  for _, node in ipairs(requestedNodes) do
    local cid = nil
    local name = nil
    if type(node) == "string" then
      name = node
      cid = nodeCache.nameToCid[name]
    else
      local n = v.data.nodes[node] or {}
      cid = n.cid
      name = n.name
    end
    if not cid then
      return false, node  -- error flag, node that does not exist
    end
    local pos = obj:getAbsNodePosition(cid)
    local mass = obj:getNodeMass(cid)
    local info = {
      name = name,
      cid = cid,
      mass = mass,
      pos = {pos.x, pos.y, pos.z},
    }
    table.insert(nodes, info)
  end
  return true, nodes -- success flag, list of nodes
end

-- Public interface
M.computeMassProperties = computeMassProperties
M.getRefNodes = getRefNodes
M.getNodeCache = getNodeCache
M.getNodeInfo = getNodeInfo

return M
