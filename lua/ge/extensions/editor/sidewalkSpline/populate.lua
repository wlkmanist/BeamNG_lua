-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this file,
-- You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local toolPrefixStr = 'Sidewalk Spline'

local maxMeshesPerSpline = 2000

local exitDist = 2.0 -- The distance from the end of the spline, at which to stop, in meters.

local pizzaMinAngleDeg = 1.0 -- Minimum turn angle in degrees to place a pizza piece.

-- Rect piece dimensions (must match authored mesh).
local rectWidth = 2.0 -- Total width across X, in meters.
local rectLength = 2.5 -- Length along the spline (local Y), in meters.

-- Pizza piece dimensions in local mesh space (must match authored mesh).
local pizzaHeight = rectLength -- Tip-to-base depth along local Y.
local pizzaHalfHeight = pizzaHeight * 0.5

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')
local util = require('editor/toolUtilities/util')

-- Module constants.
local min, max = math.min, math.max
local abs, atan2, deg = math.abs, math.atan2, math.deg
local defaultScale = vec3(1, 1, 1)

-- Module state.
local meshPools = {}
local meshPathArray, positionArray, rotationArray = {}, {}, {}
local scaleXArray, scaleYArray = {}, {}
local rectForwardArray, rectRightArray, rectUpArray = {}, {}, {}
local neededMeshes, counters = {}, {}
local maxPlacements = 0
local finalRot = quat()
local forwardRot, upRot = quat(), quat()
local tmpPosBack, tmpPosFront = vec3(), vec3()
local tmpForward, tmpUp, tmpRight = vec3(), vec3(), vec3()
local tmpVec1, tmpVec2 = vec3(), vec3()
local cornerPrev, cornerNext, baseVec = vec3(), vec3(), vec3()
local innerPrev, innerNext, interiorDir = vec3(), vec3(), vec3()
local innerPrev, innerNext, interiorDir = vec3(), vec3(), vec3()
local pizzaScaleVec = vec3(1, 1, 1)


-- Gets the folder for the given spline, and creates it if it doesn't exist.
local function getOrCreateFolder(spline, splineIdx)
  local folder = scenetree.findObjectById(spline.sceneTreeFolderId)
  if not folder then
    local uniqueName = util.generateUniqueName(toolPrefixStr .. " " .. splineIdx, toolPrefixStr)
    folder = createObject("SimGroup")
    folder:registerObject(uniqueName .. " - " .. spline.id)
    scenetree.MissionGroup:addObject(folder)
    spline.sceneTreeFolderId = folder:getId()
  end
  return folder
end

-- Manages mesh pools based on discovered placements.
local function manageMeshPools(spline, splineIdx, numPlacements)
  local splineId = spline.id
  local folder = getOrCreateFolder(spline, splineIdx)

  -- Count needed meshes per unique mesh path.
  table.clear(neededMeshes)
  for i = 1, numPlacements do
    local meshPath = meshPathArray[i]
    if meshPath then
      neededMeshes[meshPath] = (neededMeshes[meshPath] or 0) + 1
    end
  end

  -- Process each needed mesh path - add/remove only what's needed.
  meshPools[splineId] = meshPools[splineId] or {}
  for meshPath, neededCount in pairs(neededMeshes) do
    meshPools[splineId][meshPath] = meshPools[splineId][meshPath] or {}
    local pathPool = meshPools[splineId][meshPath]
    local existingCount = #pathPool
    for i = existingCount + 1, neededCount do -- Add any extra meshes that are needed.
      local obj = createObject('TSStatic')
      obj:setField('shapeName', 0, meshPath)
      local id = Engine.generateUUID()
      obj:registerObject(string.format('SidewalkMesh_%s', id))
      obj.cansave = true
      folder:addObject(obj.obj)
      pathPool[i] = obj
    end
    for i = existingCount, neededCount + 1, -1 do -- Remove any excess meshes that we no longer need.
      local mesh = pathPool[i]
      if mesh and simObjectExists(mesh) then
        mesh:delete()
      end
      pathPool[i] = nil
    end
  end

  -- Delete meshes for paths that are no longer needed.
  for meshPath, pathPool in pairs(meshPools[splineId]) do
    if not neededMeshes[meshPath] then
      for i = #pathPool, 1, -1 do
        local mesh = pathPool[i]
        if mesh and simObjectExists(mesh) then
          mesh:delete()
        end
        pathPool[i] = nil
      end
    end
  end
end

-- Evaluates spline position and frame at a given arc length s.
local function evalFrameAtArc(spline, s, posOut, forwardOut, upOut)
  local divPoints = spline.divPoints
  local normals = spline.normals
  local arcLengths = spline.arcLengths
  local totalLength = spline.totalLength or 0.0
  local numDivPoints = divPoints and #divPoints or 0
  local numArc = arcLengths and #arcLengths or 0
  if not divPoints or not normals or not arcLengths then
    return false
  end

  -- Ensure we never index beyond the arc-length table even if divPoints changed.
  numDivPoints = min(numDivPoints, numArc)
  if numDivPoints < 2 then
    return false
  end
  totalLength = arcLengths[numDivPoints] or totalLength

  if s <= 0.0 then
    local p0 = divPoints[1]
    local p1 = divPoints[2]
    posOut:set(p0)
    tmpForward:setSub2(p1, p0)
    tmpForward:normalize()
    forwardOut:set(tmpForward)
    upOut:set(normals[1])
    return true
  end

  if s >= totalLength then
    local pPrev = divPoints[numDivPoints - 1]
    local pCur = divPoints[numDivPoints]
    posOut:set(pCur)
    tmpForward:setSub2(pCur, pPrev)
    tmpForward:normalize()
    forwardOut:set(tmpForward)
    upOut:set(normals[numDivPoints])
    return true
  end

  local low, high = 1, numDivPoints
  while low < high do
    local mid = math.floor((low + high) * 0.5)
    if arcLengths[mid] < s then
      low = mid + 1
    else
      high = mid
    end
  end

  local idx = max(2, low)
  local s0 = arcLengths[idx - 1]
  local s1 = arcLengths[idx]
  local t = 0.0
  if s1 > s0 then
    t = (s - s0) / (s1 - s0)
  end

  local p0 = divPoints[idx - 1]
  local p1 = divPoints[idx]
  tmpVec1:setSub2(p1, p0)
  tmpVec1:setScaled(t)
  posOut:setAdd2(p0, tmpVec1)

  tmpForward:setSub2(p1, p0)
  tmpForward:normalize()
  forwardOut:set(tmpForward)

  local n0 = normals[idx - 1]
  local n1 = normals[idx]
  tmpVec2:setAdd2(n0, n1)
  tmpVec2:normalize()
  upOut:set(tmpVec2)

  return true
end

-- Gets the next available mesh from the pool for the given path.
local function getNextMeshFromPool(path, splineId)
  local pathPool = meshPools[splineId] and meshPools[splineId][path] or {}
  local counter = counters[path] or 1
  if counter <= #pathPool then
    counters[path] = counter + 1
    return pathPool[counter]
  end
  return nil
end

-- Main function to populate the sidewalk spline with pieces.
local function populateSidewalkSpline(spline, splineIdx)
  local rectMeshPath = spline.rectMeshPath
  local pizzaMeshPath = spline.pizzaMeshPath

  if not rectMeshPath then
    return -- Early return if we do not have a rect mesh for this spline.
  end

  local divPoints = spline.divPoints
  local normals = spline.normals
  local arcLengths = spline.arcLengths
  local totalLength = spline.totalLength or 0.0
  if not divPoints or not normals or not arcLengths or #divPoints < 2 or totalLength <= 0.0 then
    return -- Early return if we do not have valid secondary geometry.
  end

  local halfRectLength = rectLength * 0.5
  local halfRectWidth = rectWidth * 0.5

  local numPlaced = 0
  local s0 = 0.0
  local endLimit = max(0.0, totalLength - exitDist)
  local prevForward = nil
  local prevUp = nil

  while numPlaced < maxMeshesPerSpline do
    local sMid = s0 + halfRectLength
    local sEnd = sMid + halfRectLength
    if sEnd > endLimit then
      break
    end

    local placementIdx = numPlaced + 1
    if placementIdx > maxPlacements then
      maxPlacements = placementIdx
      positionArray[placementIdx] = positionArray[placementIdx] or vec3()
      rotationArray[placementIdx] = rotationArray[placementIdx] or quat()
    end

    local center = positionArray[placementIdx]
    local ok = evalFrameAtArc(spline, sMid, center, tmpForward, tmpUp)
    if not ok then
      break
    end

    -- Parallel-transport frame: preserve roll continuity along the spline.
    if prevForward and prevUp then
      forwardRot:setRotationFromTo(prevForward, tmpForward)
      tmpUp:setRotate(forwardRot, prevUp)
    end

    tmpRight:setCross(tmpForward, tmpUp)
    tmpRight:normalize()

    forwardRot:setRotationFromTo(vec3(0, 1, 0), tmpForward)
    tmpVec1:set(0, 0, 1)
    tmpVec1:setRotate(forwardRot, tmpVec1)
    upRot:setRotationFromTo(tmpVec1, tmpUp)
    finalRot:setMul2(forwardRot, upRot)

    -- For all but the first rect, translate so that the chosen inner back corner matches the previous inner front corner.
    if numPlaced > 0 then
      local prevIdx = placementIdx - 1
      local centerPrev = positionArray[prevIdx]
      local fPrev = rectForwardArray[prevIdx]
      local rPrev = rectRightArray[prevIdx]

      -- Determine inner side for this join from the turn direction in XY.
      tmpVec1:set(fPrev.x, fPrev.y, 0)
      tmpVec2:set(tmpForward.x, tmpForward.y, 0)
      local crossZ = tmpVec1.x * tmpVec2.y - tmpVec1.y * tmpVec2.x

      local innerSign = -1
      if crossZ < 0 then
        innerSign = 1
      end

      -- Previous rect front inner corner.
      tmpVec1:setScaled2(rPrev, innerSign * halfRectWidth)
      tmpVec2:setScaled2(fPrev, halfRectLength)
      tmpVec1:setAdd2(tmpVec1, tmpVec2)
      tmpVec1:setAdd2(tmpVec1, centerPrev)

      -- Current rect back inner corner (before translation).
      tmpVec2:setScaled2(tmpRight, innerSign * halfRectWidth)
      tmpPosBack:setScaled2(tmpForward, -halfRectLength)
      tmpVec2:setAdd2(tmpVec2, tmpPosBack)
      tmpVec2:setAdd2(tmpVec2, center)

      -- Delta from previous front inner corner to current back inner corner.
      tmpPosBack:setSub2(tmpVec2, tmpVec1)
      center:setSub2(center, tmpPosBack)
    end

    -- Store rect frame for pizza placement pass.
    rectForwardArray[placementIdx] = rectForwardArray[placementIdx] or vec3()
    rectForwardArray[placementIdx]:set(tmpForward)
    rectRightArray[placementIdx] = rectRightArray[placementIdx] or vec3()
    rectRightArray[placementIdx]:set(tmpRight)
    rectUpArray[placementIdx] = rectUpArray[placementIdx] or vec3()
    rectUpArray[placementIdx]:set(tmpUp)
    prevForward = prevForward or vec3()
    prevForward:set(tmpForward)
    prevUp = prevUp or vec3()
    prevUp:set(tmpUp)

    rotationArray[placementIdx]:set(finalRot)
    meshPathArray[placementIdx] = rectMeshPath
    scaleXArray[placementIdx] = 1.0
    scaleYArray[placementIdx] = 1.0

    numPlaced = placementIdx
    s0 = s0 + rectLength
  end

  if numPlaced == 0 then
    return
  end

  -- Insert pizzas between rects.
  local rectCount = numPlaced
  if pizzaMeshPath and rectCount >= 2 then
    for i = 1, rectCount - 1 do
      local fPrev = rectForwardArray[i]
      local fNext = rectForwardArray[i + 1]
      local uPrev = rectUpArray[i]
      local uNext = rectUpArray[i + 1]
      local rPrev = rectRightArray[i]
      local rNext = rectRightArray[i + 1]
      local centerPrev = positionArray[i]
      local centerNext = positionArray[i + 1]

      -- Compute turn angle in XY.
      tmpVec1:set(fPrev.x, fPrev.y, 0)
      tmpVec2:set(fNext.x, fNext.y, 0)
      local dot = tmpVec1.x * tmpVec2.x + tmpVec1.y * tmpVec2.y
      local crossZ = tmpVec1.x * tmpVec2.y - tmpVec1.y * tmpVec2.x
      if dot ~= 0 or crossZ ~= 0 then
        local angle = deg(atan2(abs(crossZ), dot))
        if angle >= pizzaMinAngleDeg then
          -- For a left turn (crossZ > 0), outer side is to the right; for a right turn, outer is to the left.
          local outerSign = crossZ > 0 and 1 or -1
          local innerSign = -outerSign

          -- Previous rect front outer corner.
          cornerPrev:setScaled2(rPrev, outerSign * halfRectWidth)
          tmpVec1:setScaled2(fPrev, halfRectLength)
          cornerPrev:setAdd2(cornerPrev, tmpVec1)
          cornerPrev:setAdd2(cornerPrev, centerPrev)

          -- Next rect back outer corner.
          cornerNext:setScaled2(rNext, outerSign * halfRectWidth)
          tmpVec1:setScaled2(fNext, -halfRectLength)
          cornerNext:setAdd2(cornerNext, tmpVec1)
          cornerNext:setAdd2(cornerNext, centerNext)

          -- Inner corners to define interior direction.
          innerPrev:setScaled2(rPrev, innerSign * halfRectWidth)
          tmpVec1:setScaled2(fPrev, halfRectLength)
          innerPrev:setAdd2(innerPrev, tmpVec1)
          innerPrev:setAdd2(innerPrev, centerPrev)

          innerNext:setScaled2(rNext, innerSign * halfRectWidth)
          tmpVec1:setScaled2(fNext, -halfRectLength)
          innerNext:setAdd2(innerNext, tmpVec1)
          innerNext:setAdd2(innerNext, centerNext)

          -- Base vector and X-scale (outer edge).
          baseVec:setSub2(cornerNext, cornerPrev)
          local baseLen = baseVec:length()
          local scaleX = rectWidth > 0 and (baseLen / rectWidth) or 1.0

          -- Interior direction vector from base midpoint towards inner midpoint.
          tmpPosBack:setAdd2(cornerPrev, cornerNext)
          tmpPosBack:setScaled(0.5) -- base midpoint
          interiorDir:setAdd2(innerPrev, innerNext)
          interiorDir:setScaled(0.5) -- inner midpoint
          interiorDir:setSub2(interiorDir, tmpPosBack)
          local interiorLen = interiorDir:length()
          if interiorLen < 1e-6 then
            goto continue_join
          end
          interiorDir:setScaled(1.0 / interiorLen) -- normalised
          local scaleY = interiorLen / pizzaHeight

          -- Build orthonormal frame: X = baseDir (outer edge), Y = outward, Z = X × Y.
          tmpForward:set(baseVec)
          tmpForward:normalize() -- baseDir

          -- Outward direction is from inner to outer, i.e. minus interiorDir.
          tmpVec1:setScaled2(interiorDir, -1)
          -- Remove any component along X to make Y orthogonal to X.
          local dotXO = tmpVec1:dot(tmpForward)
          tmpVec2:setScaled2(tmpForward, dotXO)
          tmpVec1:setSub2(tmpVec1, tmpVec2)
          if tmpVec1:length() < 1e-6 then
            -- Fallback: use rect right as outward direction.
            tmpVec1:set(rPrev)
          end
          tmpVec1:normalize()

          -- Z = X × Y.
          tmpUp:setCross(tmpForward, tmpVec1)
          tmpUp:normalize()

          -- Use setFromDir with dir=Y (outward), up=Z; this yields X = dir × up = baseDir.
          finalRot:setFromDir(tmpVec1, tmpUp)

          local placementIdx = numPlaced + 1
          if placementIdx > maxPlacements then
            maxPlacements = placementIdx
            positionArray[placementIdx] = positionArray[placementIdx] or vec3()
            rotationArray[placementIdx] = rotationArray[placementIdx] or quat()
          end

          -- Base midpoint on the outer edge.
          local center = positionArray[placementIdx]
          center:setAdd2(cornerPrev, cornerNext)
          center:setScaled(0.5)

          -- Shift origin back along local +Y so that the base edge lies on [cornerPrev, cornerNext].
          -- In mesh space, the base edge is at +pizzaHalfHeight along local Y; after scaling, that distance is pizzaHalfHeight * scaleY.
          tmpVec1:set(0, 1, 0)                 -- local +Y (tip -> base)
          tmpVec1:setRotate(finalRot, tmpVec1) -- to world space
          tmpVec1:normalize()
          tmpVec1:setScaled(pizzaHalfHeight * scaleY)
          center:setSub2(center, tmpVec1)

          rotationArray[placementIdx]:set(finalRot)
          meshPathArray[placementIdx] = pizzaMeshPath
          scaleXArray[placementIdx] = scaleX
          scaleYArray[placementIdx] = scaleY

          numPlaced = placementIdx
        end
      end
      ::continue_join::
    end
  end

  manageMeshPools(spline, splineIdx, numPlaced)

  table.clear(counters)
  for meshPath, _ in pairs(neededMeshes) do
    counters[meshPath] = 1
  end

  local splineId, verticalOffset = spline.id, spline.verticalOffset
  for i = 1, numPlaced do
    local meshPath = meshPathArray[i]
    local pos, rot = positionArray[i], rotationArray[i]
    local mesh = getNextMeshFromPool(meshPath, splineId)
    if mesh then
      mesh:setPosRot(pos.x, pos.y, pos.z + verticalOffset, rot.x, rot.y, rot.z, rot.w)
      local scaleX = scaleXArray[i] or 1.0
      local scaleY = scaleYArray[i] or 1.0
      if scaleX ~= 1.0 or scaleY ~= 1.0 then
        pizzaScaleVec.x, pizzaScaleVec.y, pizzaScaleVec.z = scaleX, scaleY, 1.0
        mesh.scale = pizzaScaleVec
      else
        mesh.scale = defaultScale
      end
    end
  end
end

-- Removes all static meshes for the given spline (matches other spline tools interface).
local function tryRemove(spline)
  local splineId = spline.id
  if not splineId then
    return -- Early return if we don't have a valid spline.
  end

  -- Clear mesh pools for this spline.
  if meshPools[splineId] then
    for _, pathPool in pairs(meshPools[splineId]) do
      for i = #pathPool, 1, -1 do
        local mesh = pathPool[i]
        if mesh and simObjectExists(mesh) then
          mesh:delete()
        end
        pathPool[i] = nil
      end
    end
    meshPools[splineId] = nil
  end
end


-- Public interface.
M.populateSidewalkSpline =                              populateSidewalkSpline
M.tryRemove =                                           tryRemove

return M