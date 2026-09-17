local M = {}

local defaultParams = {
  maxDistDirectSight = 80,
  minDistPeriphSight = 5,
  periphSightAngle = 90,
  needDirectVisualContact = true,
}

local rayHeightOffset = vec3(0, 0, 1)

local function checkSighting(observerPos, observerDir, targetPos, params)
  local dist = observerPos:distance(targetPos)
  if dist < 1e-6 then return true end

  local maxDistDirect = params.maxDistDirectSight or defaultParams.maxDistDirectSight
  local minDistPeriph = params.minDistPeriphSight or defaultParams.minDistPeriphSight
  local periphAngle = params.periphSightAngle or defaultParams.periphSightAngle

  -- early out: beyond max possible range
  if dist > maxDistDirect then return false end

  local toTarget = (targetPos - observerPos) / dist
  local dot = toTarget:dot(observerDir)
  local cosPeriphAngle = math.cos(math.rad(periphAngle))

  local t = 0
  if dot > cosPeriphAngle then
    t = (dot - cosPeriphAngle) / (1 - cosPeriphAngle)
  end

  local maxDist = lerp(minDistPeriph, maxDistDirect, t)
  if dist > maxDist then return false end

  local needVisualContact = params.needDirectVisualContact
  if needVisualContact == nil then needVisualContact = defaultParams.needDirectVisualContact end

  if needVisualContact then
    local hit = castRay(observerPos + rayHeightOffset, targetPos + rayHeightOffset, true, true)
    if hit then return false end
  end

  return true
end

local function canPlayerSeeVehicle(targetVehId, params)
  if not core_camera then return false end
  local targetObj = getObjectByID(targetVehId)
  if not targetObj then return false end

  params = params or defaultParams
  local observerPos = core_camera.getPosition()
  local observerDir = core_camera.getForward()
  local targetPos = targetObj:getPosition()

  return checkSighting(observerPos, observerDir, targetPos, params)
end

local function canVehicleSeeVehicle(observerVehId, targetVehId, params)
  local observerObj = getObjectByID(observerVehId)
  local targetObj = getObjectByID(targetVehId)
  if not observerObj or not targetObj then return false end

  params = params or defaultParams
  local observerPos = observerObj:getPosition()
  local observerDir = observerObj:getDirectionVector()
  local targetPos = targetObj:getPosition()

  return checkSighting(observerPos, observerDir, targetPos, params)
end

M.checkSighting = checkSighting
M.canPlayerSeeVehicle = canPlayerSeeVehicle
M.canVehicleSeeVehicle = canVehicleSeeVehicle

return M
