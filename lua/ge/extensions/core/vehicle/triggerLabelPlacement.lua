-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local LABEL_OFFSET_REM = "0.6em"
local FALLBACK_X = vec3(1, 0, 0)
local FALLBACK_Y = vec3(0, 1, 0)
local FALLBACK_Z = vec3(0, 0, 1)
local LOCAL_X = vec3(1, 0, 0)
local LOCAL_Y = vec3(0, 1, 0)
local LOCAL_Z = vec3(0, 0, 1)
local ROTATION_QUAT = quat()
local REUSED_BOUNDS = {}
local REUSED_PLACEMENT = { bounds = REUSED_BOUNDS }
local REUSED_CENTER_SCREEN = {}
local TMP_BASIS_X = vec3()
local TMP_BASIS_Y = vec3()
local TMP_BASIS_Z = vec3()
local TMP_ROT_X = vec3()
local TMP_ROT_Y = vec3()
local TMP_ROT_Z = vec3()
local TMP_ROTATED_UP = vec3()
local TMP_WORLD_POS = vec3()
local TMP_SCREEN_POS = {}

local function rotateVecByQuatInPlace(outVec, quatValue, inVec)
  local qx, qy, qz, qw = quatValue.x, quatValue.y, quatValue.z, quatValue.w
  local vx, vy, vz = inVec.x, inVec.y, inVec.z
  local tx = 2 * (qy * vz - qz * vy)
  local ty = 2 * (qz * vx - qx * vz)
  local tz = 2 * (qx * vy - qy * vx)
  outVec:set(
    vx - qw * tx + (qy * tz - qz * ty),
    vy - qw * ty + (qz * tx - qx * tz),
    vz - qw * tz + (qx * ty - qy * tx)
  )
end

local function readXYZ(value, defaultX, defaultY, defaultZ)
  if value == nil then return defaultX, defaultY, defaultZ end
  if type(value) == "cdata" and value.x and value.y and value.z then return value.x, value.y, value.z end
  if type(value) == "number" then return value, value, value end
  if type(value) == "table" then
    local x = value.x
    local y = value.y
    local z = value.z
    if x == nil and y == nil and z == nil then
      x = value[1]
      y = value[2]
      z = value[3]
    end
    return x or defaultX, y or defaultY, z or defaultZ
  end
  return defaultX, defaultY, defaultZ
end

local function clamp01(value)
  return math.max(0, math.min(1, value))
end

local function normalizeAngle(v)
  if math.abs(v) > (math.pi * 2 + 1e-3) then
    return math.rad(v)
  end
  return v
end

local function applyAxisAngleInPlace(xIn, yIn, zIn, axis, angle)
  if math.abs(angle) <= 1e-8 then return end
  ROTATION_QUAT:setFromAxisAngle(axis, angle)
  rotateVecByQuatInPlace(TMP_ROT_X, ROTATION_QUAT, xIn)
  rotateVecByQuatInPlace(TMP_ROT_Y, ROTATION_QUAT, yIn)
  rotateVecByQuatInPlace(TMP_ROT_Z, ROTATION_QUAT, zIn)
  xIn:set(TMP_ROT_X)
  yIn:set(TMP_ROT_Y)
  zIn:set(TMP_ROT_Z)
end

local function applyTriggerRotationsInPlace(xIn, yIn, zIn, rotatedUp, baseRotValue, actionRotValue)
  local baseX, baseY, baseZ = readXYZ(baseRotValue, 0, 0, 0)
  local rotX, rotY, rotZ = readXYZ(actionRotValue, 0, 0, 0)
  baseX = normalizeAngle(baseX)
  baseY = normalizeAngle(baseY)
  baseZ = normalizeAngle(baseZ)
  rotX = normalizeAngle(rotX)
  rotY = normalizeAngle(rotY)
  rotZ = normalizeAngle(rotZ)

  local autoYaw = math.atan2(rotatedUp:dot(xIn), rotatedUp:dot(yIn))
  -- Match C++ asyncUpdate sequence/signs:
  -- base: Y(auto+baseY), Z(-baseZ), X(-baseX)
  -- live: Y(-rotY), Z(-rotZ), X(-rotX)
  applyAxisAngleInPlace(xIn, yIn, zIn, zIn, autoYaw + baseY)
  applyAxisAngleInPlace(xIn, yIn, zIn, yIn, -baseZ)
  applyAxisAngleInPlace(xIn, yIn, zIn, xIn, -baseX)
  applyAxisAngleInPlace(xIn, yIn, zIn, zIn, -rotY)
  applyAxisAngleInPlace(xIn, yIn, zIn, yIn, -rotZ)
  applyAxisAngleInPlace(xIn, yIn, zIn, xIn, -rotX)

  xIn:normalize()
  yIn:normalize()
  zIn:normalize()
end

local function computeTriggerOrientationQuat(nz, nx, camUpwards, baseRotValue, actionRotValue)
  local baseX, baseY, baseZ = readXYZ(baseRotValue, 0, 0, 0)
  local rotX, rotY, rotZ = readXYZ(actionRotValue, 0, 0, 0)
  baseX = normalizeAngle(baseX)
  baseY = normalizeAngle(baseY)
  baseZ = normalizeAngle(baseZ)
  rotX = normalizeAngle(rotX)
  rotY = normalizeAngle(rotY)
  rotZ = normalizeAngle(rotZ)

  local qDir = quatFromDir(nz)
  local rotatedUp = qDir * LOCAL_Z
  local autoYaw = math.atan2(rotatedUp:dot(nx), rotatedUp:dot(camUpwards))

  -- C++ multQuat(a, b) pre-multiplies: a = b * a.
  qDir = quatFromEuler(0, autoYaw + baseY, 0) * qDir
  qDir = quatFromEuler(0, 0, -baseZ) * qDir
  qDir = quatFromEuler(-baseX, 0, 0) * qDir
  qDir = quatFromEuler(0, -rotY, 0) * qDir
  qDir = quatFromEuler(0, 0, -rotZ) * qDir
  qDir = quatFromEuler(-rotX, 0, 0) * qDir
  return qDir
end

local function computeTriggerBasis(vehicleObj, triggerData)
  if not vehicleObj or type(triggerData) ~= "table" then
    return FALLBACK_X, FALLBACK_Y, FALLBACK_Z
  end

  local idRef = tonumber(triggerData.idRef)
  local idX = tonumber(triggerData.idX)
  local idY = tonumber(triggerData.idY)
  if not idRef or not idX or not idY or not vehicleObj.getNodePosition then
    return FALLBACK_X, FALLBACK_Y, FALLBACK_Z
  end

  local refPos = vehicleObj:getNodePosition(idRef)
  local xPos = vehicleObj:getNodePosition(idX)
  local yPos = vehicleObj:getNodePosition(idY)

  if not refPos or not xPos or not yPos then
    return FALLBACK_X, FALLBACK_Y, FALLBACK_Z
  end

  local xAxis = TMP_BASIS_X
  local yAxis = TMP_BASIS_Y
  local zAxis = TMP_BASIS_Z

  xAxis:setSub2(xPos, refPos)
  yAxis:setSub2(yPos, refPos)
  if xAxis:length() < 1e-5 or yAxis:length() < 1e-5 then
    return FALLBACK_X, FALLBACK_Y, FALLBACK_Z
  end
  TMP_ROTATED_UP:set(yAxis)
  TMP_ROTATED_UP:normalize()
  --[[
  local refVehicle = vehicleObj:getPosition() + refPos
  simpleDebugText3d("refVehicle", refVehicle, 0.001, ColorF(1,1,1,1))
  simpleDebugText3d("xAxis", xAxis + refVehicle, 0.001, ColorF(1,0,0,1))
  simpleDebugText3d("yAxis", yAxis + refVehicle, 0.001, ColorF(0,1,0,1))
  debugDrawer:drawLine(refVehicle, xAxis + refVehicle, ColorF(1,0,0,1))
  debugDrawer:drawLine(refVehicle, yAxis + refVehicle, ColorF(0,1,0,1))
  ]]

  xAxis:normalize()
  -- Match C++ trigger basis: nz = normalize(cross(ny, nx))
  zAxis:setCross(yAxis, xAxis)
  if zAxis:length() < 1e-5 then
    return FALLBACK_X, FALLBACK_Y, FALLBACK_Z
  end
  zAxis:normalize()
  --simpleDebugText3d("zAxis", zAxis + refVehicle, 0.001, ColorF(0,0,1,1))
  --debugDrawer:drawLine(refVehicle, zAxis + refVehicle, ColorF(0,0,1,1))
  -- Match C++ camUpwards = -cross(nz, nx)
  yAxis:setCross(zAxis, xAxis)
  yAxis:setScaled(-1)
  yAxis:normalize()
  --local triggerCenter = vehicleObj:getPosition() + refPos + triggerData.baseTranslation.x * xAxis + triggerData.baseTranslation.y * yAxis + triggerData.baseTranslation.z * zAxis
  --simpleDebugText3d("triggerCenter", triggerCenter, 0.001, ColorF(1,1,1,1))
  --debugDrawer:drawLine(refVehicle, triggerCenter, ColorF(1,1,1,1))

  local qDir = computeTriggerOrientationQuat(zAxis, xAxis, yAxis, triggerData.baseRotation, triggerData.rotation)
  return qDir * LOCAL_X, qDir * LOCAL_Y, qDir * LOCAL_Z
end

local function computeHalfExtents(triggerData)
  local size = triggerData and triggerData.size or nil
  if type(size) == "number" then
    local r = math.abs(size)
    return r, r, r
  end
  local sx, sy, sz = readXYZ(size, 0.2, 0.2, 0.2)
  -- Box trigger size vectors are treated as full extents here; convert to half-extents for corner offsets.
  return math.abs(sx or 0) * 0.5, math.abs(sy or 0) * 0.5, math.abs(sz or 0) * 0.5
end

local function projectCorners(centerWorld, xAxis, yAxis, zAxis, hx, hy, hz, worldToScreenPercent01, boundsOut)
  local minX, minY = math.huge, math.huge
  local maxX, maxY = -math.huge, -math.huge
  local hasAnyCorner = false
--[[
  debugDrawer:drawLine(centerWorld, centerWorld + xAxis * hx, ColorF(1,0,0,1))
  simpleDebugText3d(string.format("x-%0.2f", hx), centerWorld + xAxis * hx, 0.01, ColorF(1,1,1,0.25))
  debugDrawer:drawLine(centerWorld, centerWorld + yAxis * hy, ColorF(0,1,0,1))
  simpleDebugText3d(string.format("y-%0.2f", hy), centerWorld + yAxis * hy, 0.01, ColorF(1,1,1,0.25))
  debugDrawer:drawLine(centerWorld, centerWorld + zAxis * hz, ColorF(0,0,1,1))
  simpleDebugText3d(string.format("z-%0.2f", hz), centerWorld + zAxis * hz, 0.01, ColorF(1,1,1,0.25))
]]
  for sx = -1, 1, 2 do
    for sy = -1, 1, 2 do
      for sz = -1, 1, 2 do
        TMP_WORLD_POS:setAddScaled(centerWorld, xAxis, hx * sx)
        TMP_WORLD_POS:setAddScaled(TMP_WORLD_POS, yAxis, hy * sy)
        TMP_WORLD_POS:setAddScaled(TMP_WORLD_POS, zAxis, hz * sz)
        --[[
        simpleDebugText3d(string.format("%d,%d,%d", sx, sy, sz), TMP_WORLD_POS, 0.01, ColorF(1,1,1,0.25))
        ]]--
        local screenPos = worldToScreenPercent01 and worldToScreenPercent01(TMP_WORLD_POS, TMP_SCREEN_POS) or nil
        if screenPos and type(screenPos.x) == "number" and type(screenPos.y) == "number" then
          hasAnyCorner = true
          local px = screenPos.x
          local py = screenPos.y
          minX = math.min(minX, px)
          maxX = math.max(maxX, px)
          minY = math.min(minY, py)
          maxY = math.max(maxY, py)
        end
      end
    end
  end

  if not hasAnyCorner then
    return false
  end
  boundsOut.minX = minX
  boundsOut.maxX = maxX
  boundsOut.minY = minY
  boundsOut.maxY = maxY
  boundsOut.centerX = (minX + maxX) * 0.5
  boundsOut.centerY = (minY + maxY) * 0.5
  return true
end

local function pickSide(bounds)
  local centerMin = 0.15
  local centerMax = 0.85
  local insideCenter70 =
    bounds.minX >= centerMin
    and bounds.maxX <= centerMax
    and bounds.minY >= centerMin
    and bounds.maxY <= centerMax
  if insideCenter70 then
    return "bottom"
  end

  local rightSpace = 1 - bounds.maxX
  local leftSpace = bounds.minX
  local topSpace = bounds.minY
  local bottomSpace = 1 - bounds.maxY

  local bestSide = "right"
  local bestSpace = rightSpace
  if leftSpace > bestSpace then
    bestSpace = leftSpace
    bestSide = "left"
  end
  if topSpace > bestSpace then
    bestSpace = topSpace
    bestSide = "top"
  end
  if bottomSpace > bestSpace then
    bestSide = "bottom"
  end
  return bestSide
end

function M.computeForTrigger(vehicleObj, triggerObj, triggerData, worldToScreenPercent01, p, centerWorld, centerScreen)
  if p then p:add("03b_pl_begin") end
  if not centerWorld then
    if not triggerObj or not triggerObj.getCenter then return nil end
    centerWorld = triggerObj:getCenter()
    if not centerWorld then return nil end
  end

  centerScreen = centerScreen or (worldToScreenPercent01 and worldToScreenPercent01(centerWorld, REUSED_CENTER_SCREEN) or nil)
  if p then p:add("03b_pl_centerToScreen") end
  local xAxis, yAxis, zAxis = computeTriggerBasis(vehicleObj, triggerData)
  if p then p:add("03b_pl_basis") end
  local hx, hy, hz = computeHalfExtents(triggerData)
  if p then p:add("03b_pl_halfExtents") end

  local bounds = REUSED_BOUNDS
  local hasProjectedBounds = projectCorners(centerWorld, xAxis, yAxis, zAxis, hx, hy, hz, worldToScreenPercent01, bounds)
  if p then p:add("03b_pl_projectCorners") end

  if not hasProjectedBounds and centerScreen then
    local x = clamp01(centerScreen.x)
    local y = clamp01(centerScreen.y)
    bounds.minX = x
    bounds.maxX = x
    bounds.minY = y
    bounds.maxY = y
    bounds.centerX = x
    bounds.centerY = y
    hasProjectedBounds = true
    if p then p:add("03b_pl_fallbackBounds") end
  end
  if not hasProjectedBounds then return nil end

  local side = pickSide(bounds)
  if p then p:add("03b_pl_pickSide") end
  local labelX, labelY, labelTx, labelTy
  if side == "right" then
    labelX = bounds.maxX
    labelY = bounds.centerY
    labelTx = LABEL_OFFSET_REM
    labelTy = "-50%"
  elseif side == "left" then
    labelX = bounds.minX
    labelY = bounds.centerY
    labelTx = "calc(-100% - " .. LABEL_OFFSET_REM .. ")"
    labelTy = "-50%"
  elseif side == "top" then
    labelX = bounds.centerX
    labelY = bounds.minY
    labelTx = "-50%"
    labelTy = "calc(-100% - " .. LABEL_OFFSET_REM .. ")"
  else
    labelX = bounds.centerX
    labelY = bounds.maxY
    labelTx = "-50%"
    labelTy = LABEL_OFFSET_REM
  end

  local out = REUSED_PLACEMENT
  out.labelX = clamp01(labelX)
  out.labelY = clamp01(labelY)
  out.labelTx = labelTx
  out.labelTy = labelTy
  out.labelSide = side
  out.bounds = bounds
  if p then p:add("03b_pl_complete") end
  return out
end

-- Shared by debug/highlight drawing to ensure basis/extents stay in sync with placement logic.
function M.computeTriggerBasisAndHalfExtents(vehicleObj, triggerData)
  local basisX, basisY, basisZ = computeTriggerBasis(vehicleObj, triggerData)
  local hx, hy, hz = computeHalfExtents(triggerData)
  return basisX, basisY, basisZ, hx, hy, hz
end

return M
