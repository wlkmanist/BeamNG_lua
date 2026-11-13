-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local settleDelay = 0.12
local state = {}

local function reset()
  state.status = "waiting"
  state.camera = nil
  state.configKey = nil
  state.lastMotionTime = os.clock()
  state.data = nil
  state.buildTime = 0
  state.classificationTime = 0
  state.reason = "reset"
end

local function captureCamera(camera)
  return {
    pos = vec3(camera.pos),
    rangeOrigin = vec3(camera.rangeOrigin or camera.pos),
    forward = vec3(camera.forward),
    up = vec3(camera.up),
    halfTan = camera.halfTan,
    width = camera.width,
    height = camera.height
  }
end

local function cameraChanged(camera, previous)
  if not previous then return true end
  if (camera.pos - previous.pos):squaredLength() > 0.0001 then return true end
  if ((camera.rangeOrigin or camera.pos) - previous.rangeOrigin):squaredLength() > 0.0001 then
    return true
  end
  if camera.forward:dot(previous.forward) < 0.999999 then return true end
  if camera.up:dot(previous.up) < 0.999999 then return true end
  if math.abs(camera.halfTan - previous.halfTan) > 0.000001 then return true end
  return camera.width ~= previous.width or camera.height ~= previous.height
end

function M.activate()
  reset()
end

function M.invalidate(reason)
  state.status = "waiting"
  state.data = nil
  state.lastMotionTime = os.clock()
  state.reason = reason or "invalidated"
end

function M.update(camera, configKey, build)
  local now = os.clock()
  if cameraChanged(camera, state.camera) then
    state.camera = captureCamera(camera)
    state.configKey = configKey
    state.status = "moving"
    state.data = nil
    state.lastMotionTime = now
    state.reason = "camera"
    return nil
  end

  if state.configKey ~= configKey then
    state.configKey = configKey
    M.invalidate("settings")
    return nil
  end

  if state.data then
    state.status = "ready"
    return state.data
  end

  if now - state.lastMotionTime < settleDelay then
    if state.status ~= "moving" then state.status = "waiting" end
    return nil
  end

  state.status = "building"
  local timer = hptimer()
  state.data = build()
  state.buildTime = timer:stopAndReset()
  state.status = "ready"
  state.reason = nil
  return state.data
end

function M.setClassificationTime(milliseconds)
  state.classificationTime = milliseconds or 0
end

function M.getStatus()
  return {
    status = state.status,
    reason = state.reason,
    targetCount = state.data and #(state.data.proxies or {}) or 0,
    buildTime = state.buildTime or 0,
    classificationTime = state.classificationTime or 0
  }
end

reset()

return M
