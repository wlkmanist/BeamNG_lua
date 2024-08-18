-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
M.moduleActions = {}
M.moduleLookups = {}

local max = math.max
local moduleName = "interactCargoContainers"

local expressionParser

local cargoContainerCache = nil
local cargoContainerById = nil
local cargoContainerGroupIdToCid = nil

local functionFieldNames = {
  nodeWeightFunction = true,
  beamSpringFunction = true,
  beamLimitSpringFunction = true,
  beamDampFunction = true,
  nodeWeightFunction = true,
  beamStrengthFunction = true,
  beamDeformFunction = true,
  beamShortBoundFunction = true,
  beamLongBoundFunction = true,
}

local function buildContainerCache()
  cargoContainerCache = {}
  cargoContainerById = {}
  local cargoContainerGroupIdToCacheIndex = {}
  local cargoContainerGroupIdToCid = {}
  local idx = 1
  for _, container in pairs(v.data.cargoStorage or {}) do
    -- generate an entry for the list that will be sent back to geLua.
    local entry = {
      id = container.cid,
      cargoTypes = container.cargoTypes,
      capacity = container.capacity,
      name = container.name or "Unnamed Container",
      groupId = container.groupId,
      partOrigin = container.partOrigin,
    }
    table.insert(cargoContainerCache, entry)

    cargoContainerById[container.cid] = {nodes = {}, beams = {}}
    cargoContainerGroupIdToCacheIndex[container.groupId..container.partOrigin] = idx
    cargoContainerGroupIdToCid[container.groupId..container.partOrigin] = container.cid
    idx = idx + 1
  end

  -- store all nodes for groups
  for _, node in pairs(v.data.nodes) do
    if node.cargoGroup and cargoContainerGroupIdToCacheIndex[node.cargoGroup..node.partOrigin] then
      local hasValidFunction = true
      for functionName, _ in pairs(functionFieldNames) do
        if node[functionName] then
          hasValidFunction = true
        end
      end
      if hasValidFunction then
        table.insert(cargoContainerById[cargoContainerGroupIdToCid[node.cargoGroup..node.partOrigin]].nodes, node.cid)

      end

      -- give one of the node id's to the entry, so that geLua can use it for detachment test
      cargoContainerCache[cargoContainerGroupIdToCacheIndex[node.cargoGroup..node.partOrigin]].nodeId = node.cid
    end
  end

  -- store all beams for groups
  for _, beam in pairs(v.data.beams) do
    if beam.cargoGroup and cargoContainerGroupIdToCacheIndex[beam.cargoGroup..beam.partOrigin] then
      local hasValidFunction = true
      for functionName, _ in pairs(functionFieldNames) do
        if beam[functionName] then
          hasValidFunction = true
        end
      end
      if hasValidFunction then
        table.insert(cargoContainerById[cargoContainerGroupIdToCid[beam.cargoGroup..beam.partOrigin]].beams, beam.cid)
      end
    end
  end

  -- wrap cargoContainerCache another time to conform to return value format for gameplay interface functions.
  cargoContainerCache = {cargoContainerCache}
end

local functionCache = {}
local function clearFunctionResults()
  for expr, data in pairs(functionCache) do
    data.result = nil
  end
end

local function getFunctionResult(expr, load)
  if not functionCache[expr] then
    expressionParser = expressionParser or require("jbeam/expressionParser")
    local fun, vars = expressionParser.compileSafe("$"..expr)
    functionCache[expr] = {fun = fun, vars = vars, result = nil}
  end
  if not functionCache[expr].result then
    functionCache[expr].vars["$load"] = load
    functionCache[expr].result = functionCache[expr].fun()
    --dump(expr, functionCache[expr].result)
  end
  return functionCache[expr].result
end


local function applyNodeAndBeamValues(container, load)
  clearFunctionResults()

  for _, nodeId in ipairs(container.nodes) do
    local node = v.data.nodes[nodeId]
    if node.nodeWeightFunction then
      local nodeWeight = node.nodeWeight
      --dump("setNodeMass From", node.cid, nodeWeight)
      nodeWeight = getFunctionResult(node.nodeWeightFunction, load)
      obj:setNodeMass(node.cid, nodeWeight)
      --dump("setNodeMass To  ", node.cid, nodeWeight)
    end
  end

  for _, beamId in ipairs(container.beams) do
    local beam = v.data.beams[beamId]

    if beam.beamSpringFunction or beam.beamDampFunction then
      local beamSpring = beam.beamSpring
      local beamDamp   = beam.beamDamp
      --dump("setBeamSpringDamp From", beam.cid, beamSpring, beamDamp)

      if beam.beamSpringFunction then
        beamSpring      = getFunctionResult(beam.beamSpringFunction, load)
      end
      if beam.beamDampFunction then
        beamDamp        = getFunctionResult(beam.beamDampFunction, load)
      end
      obj:setBeamSpringDamp(beam.cid, beamSpring, beamDamp, -1, -1)
      --dump("setBeamSpringDamp To  ", beam.cid, beamSpring, beamDamp)
    end

    if beam.beamLimitSpringFunction or beam.beamLimitDampFunction then
      local beamLimitSpring = -1
      local beamLimitDamp   = -1
      --dump("setBeamSpringDamp From", beam.cid, beamSpring, beamDamp)
      if beam.beamLimitSpringFunction then
        beamLimitSpring = getFunctionResult(beam.beamLimitSpringFunction, load)
      end
      if beam.beamLimitDampFunction then
        beamLimitDamp   = getFunctionResult(beam.beamLimitDampFunction, load)
      end
      obj:setBoundedBeamSpringDampLimits(beamId, beamLimitSpring, beamLimitDamp, -1)
      --dump("setBeamSpringDamp To  ", beam.cid, beamSpring, beamDamp)
    end

    if beam.beamStrengthFunction then
      local beamStrength = beam.beamStrength
      --dump("setBeamStrength From", beam.cid, beamStrength)
      beamStrength = getFunctionResult(beam.beamStrengthFunction, load)
      obj:setBeamStrength(beam.cid, beamStrength)
      --dump("setBeamStrength To  ", beam.cid, beamStrength)
    end
    if beam.beamDeformFunction then
      local beamDeform = beam.beamDeform
      --dump("beamDeform From", beam.cid, beamDeform)
      beamDeform = getFunctionResult(beam.beamDeformFunction, load)
      obj:setBeamDeform(beam.cid, beamDeform)
      --dump("beamDeform To  ", beam.cid, beamDeform)
    end

    if beam.beamShortBoundFunction then
      local beamShortBound = beam.beamShortBound
      --dump("setBoundedBeamShortBound From", beam.cid, beamShortBound)
      beamShortBound = getFunctionResult(beam.beamShortBoundFunction, load)
      obj:setBoundedBeamShortBound(beam.cid, beamShortBound)
      --dump("setBoundedBeamShortBound To  ", beam.cid, beamShortBound)
    end

    if beam.beamLongBoundFunction then
      local beamLongBound = beam.beamLongBound
      --dump("setBoundedBeamLongBound From", beam.cid, beamLongBound)
      beamLongBound = getFunctionResult(beam.beamLongBoundFunction, load)
      obj:setBoundedBeamLongBound(beam.cid, beamLongBound)
      --dump("setBoundedBeamLongBound To  ", beam.cid, beamLongBound)
    end

  end

end


local function setCargoContainers(params)
  local dataTypeCheck, dataTypeError = checkTableDataTypes(params, {"table"})
  if not dataTypeCheck then
    return {failReason = dataTypeError}
  end

  if not cargoContainerCache then
    buildContainerCache()
  end



  -- set all container weights according to the params data.
  for _, setContainerData in pairs(params[1] or {}) do
    if not setContainerData.containerId or not setContainerData.load then
      return {failReason = "Container Data missing either containerId or load values."}
    end

    local load = setContainerData.load
    applyNodeAndBeamValues(cargoContainerById[setContainerData.containerId], load)

  end

end

local function getCargoContainers(params)
  local dataTypeCheck, dataTypeError = checkTableDataTypes(params, {})
  if not dataTypeCheck then
    return {failReason = dataTypeError}
  end
  -- create the cache if it doesnt exist yet.
  if not cargoContainerCache then
    buildContainerCache()
  end
  return cargoContainerCache
end

local function requestRegistration(gi)
  gi.registerModule(moduleName, M.moduleActions, M.moduleLookups)
end

local function onExtensionLoaded()
  M.moduleActions.setCargoContainers = setCargoContainers
  M.moduleLookups.getCargoContainers = getCargoContainers
end

M.onExtensionLoaded = onExtensionLoaded
M.requestRegistration = requestRegistration

return M
