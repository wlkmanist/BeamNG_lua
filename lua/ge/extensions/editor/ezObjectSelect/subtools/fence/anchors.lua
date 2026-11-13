-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local objectBoxAnchors = require("editor/ezObjectSelect/objectBoxAnchors")

local connectionColor = ColorF(1, 0.75, 0.1, 0.9)

local function normalizedPath(value)
  if not value or value == "" then return nil end
  return value:gsub("\\", "/"):gsub("^/", ""):lower()
end

local function assetSet(paths)
  local result = {}
  for _, value in ipairs(paths or {}) do
    local key = normalizedPath(value)
    if key then result[key] = true end
  end
  return result
end

local function upcastObject(value)
  return value and (Sim.upcast(value) or value) or nil
end

local function descriptorForObject(obj, allowedAssets)
  if not obj or not obj.getClassName or obj:getClassName() ~= "TSStatic" then return nil end
  if obj.isGlobalBounds and obj:isGlobalBounds() then return nil end

  local shapePath = obj:getField("shapeName", 0)
  if not allowedAssets[normalizedPath(shapePath)] then return nil end
  local boxDescription = objectBoxAnchors.describeObject(obj)
  if not boxDescription then return nil end
  local firstPosition = boxDescription.shortEdgeOrigin.first
  local secondPosition = boxDescription.shortEdgeOrigin.second
  local direction = secondPosition - firstPosition
  local length = direction:length()
  if length <= 0.001 then return nil end
  direction = direction / length

  return {
    id = obj:getID(),
    obj = obj,
    shapePath = shapePath,
    length = length,
    anchors = {
      {position = firstPosition, outward = -direction},
      {position = secondPosition, outward = direction}
    }
  }
end

local function queryObjects(position, distance)
  local box = Box3F()
  local diameter = distance * 2
  box:setExtents(vec3(diameter, diameter, diameter))
  box:setCenter(position)
  return findObjectList(box, SOTStaticShape, 0) or {}
end

local function nearestAnchor(descriptor, anchorIndex, context)
  local sourceAnchor = descriptor.anchors[anchorIndex]
  local best
  for _, rawObject in ipairs(queryObjects(sourceAnchor.position, context.distance)) do
    local obj = upcastObject(rawObject)
    local objectId = obj and obj.getID and obj:getID() or nil
    if objectId and objectId ~= descriptor.id then
      local candidate = context.descriptors[objectId]
      if candidate == nil then
        candidate = descriptorForObject(obj, context.allowedAssets) or false
        context.descriptors[objectId] = candidate
      end
      if candidate then
        for candidateAnchorIndex, candidateAnchor in ipairs(candidate.anchors) do
          local delta = candidateAnchor.position - sourceAnchor.position
          local distanceSquared = delta:squaredLength()
          if distanceSquared <= context.distanceSquared
            and (not best or distanceSquared < best.distanceSquared) then
            best = {
              descriptor = candidate,
              anchorIndex = candidateAnchorIndex,
              distanceSquared = distanceSquared
            }
          end
        end
      end
    end
  end
  return best
end

local function mutualMatch(descriptor, anchorIndex, context)
  local match = nearestAnchor(descriptor, anchorIndex, context)
  if not match then return nil end
  local reverse = nearestAnchor(match.descriptor, match.anchorIndex, context)
  if not reverse
    or reverse.descriptor.id ~= descriptor.id
    or reverse.anchorIndex ~= anchorIndex then
    return nil
  end
  return match
end

local function edgeCount(edges)
  local count = 0
  for _ in pairs(edges or {}) do count = count + 1 end
  return count
end

local function orderedIds(graph, seedId)
  local startId = seedId
  for objectId, edges in pairs(graph) do
    if edgeCount(edges) <= 1 then
      startId = objectId
      break
    end
  end

  local result, previousId, currentId = {}, nil, startId
  local seen = {}
  while currentId and not seen[currentId] do
    seen[currentId] = true
    result[#result + 1] = currentId
    local nextId
    for neighborId in pairs(graph[currentId] or {}) do
      if neighborId ~= previousId then
        nextId = neighborId
        break
      end
    end
    previousId, currentId = currentId, nextId
  end
  return result
end

local function connection(graph, firstId, secondId)
  return graph[firstId] and graph[firstId][secondId] or nil
end

local function midpoint(first, second)
  return (first + second) * 0.5
end

local function buildJoints(ids, graph, descriptors, isLoop)
  local joints = {}
  if #ids == 0 then return joints end
  if #ids == 1 then
    joints[1] = vec3(descriptors[ids[1]].anchors[1].position)
    joints[2] = vec3(descriptors[ids[1]].anchors[2].position)
    return joints
  end

  if not isLoop then
    local firstEdge = connection(graph, ids[1], ids[2])
    local firstDescriptor = descriptors[ids[1]]
    local freeAnchorIndex = firstEdge.sourceAnchorIndex == 1 and 2 or 1
    joints[#joints + 1] = vec3(firstDescriptor.anchors[freeAnchorIndex].position)
  end

  local pairCount = isLoop and #ids or #ids - 1
  for index = 1, pairCount do
    local nextIndex = index % #ids + 1
    local edge = connection(graph, ids[index], ids[nextIndex])
    if edge then
      local firstAnchor = descriptors[ids[index]].anchors[edge.sourceAnchorIndex].position
      local secondAnchor = descriptors[ids[nextIndex]].anchors[edge.targetAnchorIndex].position
      joints[#joints + 1] = midpoint(firstAnchor, secondAnchor)
    end
  end

  if not isLoop then
    local lastIndex = #ids
    local lastEdge = connection(graph, ids[lastIndex], ids[lastIndex - 1])
    local lastDescriptor = descriptors[ids[lastIndex]]
    local freeAnchorIndex = lastEdge.sourceAnchorIndex == 1 and 2 or 1
    joints[#joints + 1] = vec3(lastDescriptor.anchors[freeAnchorIndex].position)
  end
  return joints
end

function M.discover(seedObjectId, options)
  options = options or {}
  local allowedAssets = assetSet(options.assetPaths)
  local seedObject = scenetree.findObjectById(seedObjectId)
  local seedDescriptor = descriptorForObject(seedObject, allowedAssets)
  if not seedDescriptor then return nil, "The object selected in Easy Select is not an eligible fence piece" end

  local distance = math.max(options.distance or 0.5, 0.001)
  local context = {
    allowedAssets = allowedAssets,
    distance = distance,
    distanceSquared = distance * distance,
    descriptors = {[seedDescriptor.id] = seedDescriptor}
  }
  local graph = {}
  local queue = {seedDescriptor.id}
  local queued = {[seedDescriptor.id] = true}
  local cursor = 1
  local maximumPieces = math.max(1, options.maximumPieces or 2048)
  local capped = false

  while cursor <= #queue do
    local objectId = queue[cursor]
    cursor = cursor + 1
    local descriptor = context.descriptors[objectId]
    graph[objectId] = graph[objectId] or {}
    for anchorIndex = 1, 2 do
      local match = mutualMatch(descriptor, anchorIndex, context)
      if match then
        local neighborId = match.descriptor.id
        if not queued[neighborId] then
          if #queue >= maximumPieces then
            capped = true
          else
            queued[neighborId] = true
            queue[#queue + 1] = neighborId
          end
        end
        if queued[neighborId] then
          graph[neighborId] = graph[neighborId] or {}
          graph[objectId][neighborId] = {
            sourceAnchorIndex = anchorIndex,
            targetAnchorIndex = match.anchorIndex
          }
          graph[neighborId][objectId] = {
            sourceAnchorIndex = match.anchorIndex,
            targetAnchorIndex = anchorIndex
          }
        end
      end
    end
  end

  local ids = orderedIds(graph, seedDescriptor.id)
  local isLoop = #ids > 2
    and edgeCount(graph[ids[1]]) == 2
    and edgeCount(graph[ids[#ids]]) == 2
  return {
    ids = ids,
    graph = graph,
    descriptors = context.descriptors,
    joints = buildJoints(ids, graph, context.descriptors, isLoop),
    isLoop = isLoop,
    capped = capped
  }
end

function M.draw(result)
  if not result then return end
  for index = 1, #(result.joints or {}) - 1 do
    debugDrawer:drawLine(result.joints[index], result.joints[index + 1], connectionColor)
  end
  if result.isLoop and #result.joints > 2 then
    debugDrawer:drawLine(result.joints[#result.joints], result.joints[1], connectionColor)
  end
end

return M
