-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Replaces stock wheel movement with a smooth dolly along the view center.
-- Each wheel step changes distance proportionally, while collision
-- checks keep the camera from passing through terrain or scene geometry.

local M = {}

local validation = require("editor/cameraV2/validation")
local centerRayDistance = 100000
local fallbackDistance = 50
local state = nil
local lastTerrainOnly = false

local function preference(name, fallback)
  return editor.getPreference("camera.cameraV2." .. name) or fallback
end

local function cameraForward()
  local forward = core_camera.getQuat() * vec3(0, 1, 0)
  if forward:length() > 0.0001 then forward:normalize() end
  return forward
end

local function mouseGestureRequested()
  return ui_imgui.IsMouseDown(1)
    or ui_imgui.IsMouseDown(2)
end

local function reconcileCameraTranslation()
  local cameraPosition = vec3(core_camera.getPosition())
  if not validation.isReasonablePoint(cameraPosition)
    or not validation.isReasonablePoint(state.expectedPosition)
    or not validation.isReasonablePoint(state.focus)
    or math.abs(core_camera.getQuat():dot(state.expectedRotation)) < 0.99999 then
    return false
  end
  local focus = state.focus + cameraPosition - state.expectedPosition
  if not validation.isReasonablePoint(focus) then return false end
  state.focus = focus
  state.expectedPosition = cameraPosition
  return true
end

local function clampDistanceToTerrainOnly(origin, direction, distance)
  if distance <= 0 or not core_terrain.getTerrain() then return distance end
  local terrainClearance = math.max(preference("zoomMinDistance", 0.25), 0.01)
  local function isAboveTerrain(amount)
    local position = origin + direction * amount
    local terrainHeight = validation.terrainHeightAt(position)
    return not terrainHeight or position.z >= terrainHeight + terrainClearance
  end
  local low, high = 0, nil
  for index = 1, 64 do
    local amount = distance * index / 64
    if not isAboveTerrain(amount) then
      high = amount
      break
    end
    low = amount
  end
  if not high then return distance end
  for _ = 1, 12 do
    local middle = (low + high) * 0.5
    if isAboveTerrain(middle) then low = middle else high = middle end
  end
  return low
end

local function clampDistanceToScene(origin, direction, distance)
  if distance <= 0 then return distance end
  local terrainClearance = math.max(preference("zoomMinDistance", 0.25), 0.01)
  local terrain = core_terrain.getTerrain()
  local hitDistance = castRayStatic(origin, direction, distance)
  if hitDistance == nil then return nil end
  if not validation.isFinite(hitDistance)
    or hitDistance < 0
    or hitDistance > distance then
    return nil
  end
  local function isAboveTerrain(amount)
    if not terrain then return true end
    local position = origin + direction * amount
    local terrainHeight = validation.terrainHeightAt(position)
    return not terrainHeight or position.z >= terrainHeight + terrainClearance
  end

  if hitDistance >= distance and isAboveTerrain(distance) then return distance end
  if not terrain then return math.max(hitDistance - 0.1, 0) end
  local high = math.min(hitDistance, distance)
  if isAboveTerrain(high) then
    return math.max(high - 0.1, 0)
  end

  local low = 0
  for _ = 1, 12 do
    local middle = (low + high) * 0.5
    if isAboveTerrain(middle) then low = middle else high = middle end
  end
  return low
end

local function zoomAnchor(origin, fallback)
  local direction = cameraForward()
  if not validation.isValidPoint(direction) or direction:length() <= 0.0001 then return nil end
  direction:normalize()
  local hit = Engine.castRay(
    origin,
    origin + direction * centerRayDistance,
    true,
    true)
  local focus = hit
    and hit.pt
    and validation.isPointOnRaySegment(
      hit.pt,
      origin,
      direction,
      centerRayDistance)
    and vec3(hit.pt)
    or nil
  if not focus then
    focus = origin + direction * fallback
  end

  local distance = (focus - origin):length()
  if not validation.isFinite(distance) then return nil end
  if distance <= 0.0001 then
    focus = origin + direction * fallback
    distance = fallback
  else
    direction = (focus - origin) / distance
  end
  return focus, direction, distance, false
end

local function setCameraForLogDistance(logDistance)
  local origin = vec3(core_camera.getPosition())
  if not validation.isFinite(logDistance) or not validation.isValidPoint(origin) then
    return false
  end
  local desiredPosition = state.focus - state.direction * math.exp(logDistance)
  if not validation.isReasonablePoint(desiredPosition) then return false end
  if state.zoomingIn then
    local path = desiredPosition - origin
    local pathLength = path:length()
    if pathLength > 0.0001 then
      local pathDirection = path / pathLength
      local allowedDistance = state.terrainOnly
        and clampDistanceToTerrainOnly(origin, pathDirection, pathLength)
        or clampDistanceToScene(origin, pathDirection, pathLength)
      if allowedDistance == nil then return false end
      if allowedDistance < pathLength then
        local position = origin + pathDirection * allowedDistance
        core_camera.setPosition(0, position)
        state.expectedPosition = vec3(position)
        state.currentLogDistance = math.log(
          math.max((state.focus - position):length(), 0.0001))
        state.targetLogDistance = state.currentLogDistance
        return false
      end
    end
  end
  core_camera.setPosition(0, desiredPosition)
  state.expectedPosition = vec3(desiredPosition)
  state.currentLogDistance = logDistance
  return true
end

function M.onMouseWheel(value, fixedFocus)
  if math.abs(value) <= 0.0001 then return false end
  local origin = vec3(core_camera.getPosition())
  if not validation.isReasonablePoint(origin) then return true end
  local minimum = math.max(preference("zoomMinDistance", 0.25), 0.0001)
  local maximum = clamp(preference("zoomMaxDistance", 2500), minimum, 2500)
  local fallback = clamp(fallbackDistance, minimum, maximum)
  local zoomingIn = value > 0
  local focus
  local direction
  local distance
  local terrainOnly
  if validation.isReasonablePoint(fixedFocus) then
    focus = vec3(fixedFocus)
    direction = focus - origin
    distance = direction:length()
    if distance > 0.0001 then direction = direction / distance end
    terrainOnly = false
  else
    focus, direction, distance, terrainOnly = zoomAnchor(origin, fallback)
  end
  lastTerrainOnly = terrainOnly == true
  if not focus
    or not validation.isReasonablePoint(focus)
    or not validation.isValidPoint(direction)
    or not validation.isFinite(distance) then
    state = nil
    return true
  end

  local pendingLogDistance = 0
  if state and state.zoomingIn == zoomingIn then
    pendingLogDistance = state.targetLogDistance - state.currentLogDistance
  end
  local currentLogDistance = math.log(math.max(distance, 0.0001))
  local sensitivity = math.log(math.max(preference("zoomFactorPerNotch", 1.5), 1.0001))
  local targetLogDistance = clamp(
    currentLogDistance + pendingLogDistance - value * sensitivity,
    math.log(minimum),
    math.log(maximum))
  if not validation.isFinite(currentLogDistance)
    or not validation.isFinite(targetLogDistance) then
    state = nil
    return true
  end
  state = {
    focus = focus,
    direction = direction,
    currentLogDistance = currentLogDistance,
    targetLogDistance = targetLogDistance,
    zoomingIn = zoomingIn,
    terrainOnly = terrainOnly,
    expectedPosition = origin,
    expectedRotation = quat(core_camera.getQuat())
  }
  if core_camera.clearAngularMotion then
    core_camera.clearAngularMotion(0)
  elseif core_camera.clearMotion then
    core_camera.clearMotion(0)
  end
  return true
end

function M.update(deltaTime)
  if not state then return end
  if mouseGestureRequested() or not reconcileCameraTranslation() then
    state = nil
    return
  end

  deltaTime = clamp(deltaTime or ui_imgui.GetIO().DeltaTime or 0, 0, 0.05)
  local remaining = state.targetLogDistance - state.currentLogDistance
  if math.abs(remaining) <= 0.0001 then
    setCameraForLogDistance(state.targetLogDistance)
    state = nil
    return
  end
  local amount = 1 - math.exp(-preference("zoomResponse", 20) * deltaTime)
  if not setCameraForLogDistance(state.currentLogDistance + remaining * amount) then
    state = nil
  end
end

function M.cancel()
  state = nil
end

function M.isActive()
  return state ~= nil
end

function M.lastZoomUsedTerrainOnly()
  return lastTerrainOnly
end

return M
