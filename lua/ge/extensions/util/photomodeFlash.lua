-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = "util_photomodeFlash"

local CONFIG = {
  intensityDefault = 25000,
  intensityMin = 0,
  intensityMax = 1000000,
  innerAngle = 0,
  outerAngleDefault = 55,
  outerAngleMin = 1,
  outerAngleMax = 179,
  range = 40,
  hueDefault = 0,
  saturationDefault = 0,
  offsetHorizontal = 0.12,
  offsetVertical = 0.06,
  offsetForward = 0.05,
  aimRayDistanceMin = 5,
  shadowTexSize = 1024,
  attenuationRatio = "1 0 0",
  pulseWarmupFrames = 2,
  pulseCleanupFrames = 1,
  pulseFallbackFrames = 60,
}

M.enabled = false
M.mode = "always"
M.intensity = CONFIG.intensityDefault
M.outerAngle = CONFIG.outerAngleDefault
M.hue = CONFIG.hueDefault
M.saturation = CONFIG.saturationDefault
M.capturePulseActive = false

local spotLight = nil
local pendingPulseCapture = nil

local function clamp(value, default, min, max)
  local n = tonumber(value)
  if not n then
    return default
  end
  return math.max(min, math.min(max, math.floor(n + 0.5)))
end

local function registryGet(name)
  if not VariableRegistry or type(VariableRegistry.get) ~= "function" then
    return nil
  end
  local ok, value = pcall(VariableRegistry.get, name)
  if not ok then
    return nil
  end
  return value
end

local function getCameraAimPoint(camPos, forward)
  local rayDistance = math.max(CONFIG.range, CONFIG.aimRayDistanceMin)
  if type(castRay) == "function" then
    local hit = castRay(camPos, camPos + forward * rayDistance, true, true)
    if hit and hit.pt then
      return vec3(hit.pt)
    end
  end

  local aimDistance = math.max(CONFIG.range * 0.5, CONFIG.aimRayDistanceMin)
  local autofocus = registryGet("$DOFPostFx::EnableAutoFocus")
  if autofocus == true or autofocus == 1 or autofocus == "1" or autofocus == "true" then
    local focusRange = tonumber(registryGet("$DOFPostFx::FocusRangeMax"))
    if focusRange and focusRange > 0.5 then
      aimDistance = focusRange
    end
  end

  return camPos + forward * aimDistance
end

local function buildLightRotation(lightPos, aimPoint, upReference)
  local aimDir = vec3(aimPoint) - vec3(lightPos)
  if aimDir:squaredLength() < 1e-8 then
    return nil
  end

  aimDir:normalize()
  local up = vec3(upReference)
  if up:squaredLength() < 1e-8 then
    up = vec3(0, 0, 1)
  else
    up:normalize()
  end

  if math.abs(aimDir:dot(up)) > 0.98 then
    up = vec3(0, 1, 0)
  end

  return quatFromDir(aimDir, up):toTorqueQuat()
end

local function setLightField(object, fieldName, value, isNumber)
  if not object or value == nil then
    return
  end

  if isNumber then
    local n = tonumber(value)
    if not n then
      return
    end
    pcall(function()
      object[fieldName] = n
    end)
    object:setField(fieldName, 0, tostring(n))
    return
  end

  object:setField(fieldName, 0, tostring(value))
end

local function isActiveCamera()
  local vuePhotomodeOpen = extensions
    and extensions.ui_photomode_shared
    and extensions.ui_photomode_shared.S
    and extensions.ui_photomode_shared.S.photoModeOpen == true
  if photoModeOpen ~= true and vuePhotomodeOpen ~= true then
    return false
  end
  if not core_camera or type(core_camera.getPosition) ~= "function" then
    return false
  end

  if type(core_camera.getActiveCamName) == "function" and core_camera.getActiveCamName() == "path" then
    return false
  end

  return true
end

local function destroySpotLight()
  if not spotLight then
    return
  end

  local light = spotLight
  spotLight = nil

  if editor and editor.onRemoveSceneTreeObjects and light.getId then
    editor.onRemoveSceneTreeObjects({ light:getId() })
  end

  light:delete()
end

local function applySpotLightFields(object, active)
  local r, g, b = HSVtoRGB(M.hue / 360, M.saturation / 100, 1)
  setLightField(object, "innerAngle", CONFIG.innerAngle, true)
  setLightField(object, "outerAngle", M.outerAngle, true)
  setLightField(object, "range", CONFIG.range, true)
  setLightField(object, "color", string.format("%g %g %g 1", r, g, b), false)
  setLightField(object, "useColorTemperature", "false", false)
  setLightField(object, "isEnabled", active and "true" or "false", false)
  setLightField(object, "intensity", active and M.intensity or 0, true)
end

local function createSpotLight()
  destroySpotLight()

  local object = (worldEditorCppApi and worldEditorCppApi.createObject and worldEditorCppApi.createObject("SpotLight"))
    or (createObject and createObject("SpotLight"))
  if not object then
    log("E", logTag, "Failed to create SpotLight")
    return false
  end

  object.canSave = false
  setLightField(object, "attenuationRatio", CONFIG.attenuationRatio, false)
  object:setField("castShadows", 0, "true")
  object:setField("texSize", 0, tostring(CONFIG.shadowTexSize))
  applySpotLightFields(object, true)

  object:registerObject("PhotomodeFlash_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)))

  if scenetree and scenetree.MissionGroup then
    scenetree.MissionGroup:add(object)
  end

  if editor and editor.onAddSceneTreeObjects and object.getId then
    editor.onAddSceneTreeObjects({ object:getId() })
  end

  spotLight = object
  return true
end

local function shouldLightBeActive()
  return M.enabled and (M.mode ~= "pulse" or M.capturePulseActive)
end

local function applyLightState()
  if not spotLight or not isActiveCamera() then
    return
  end

  local camPos = core_camera.getPosition()
  local forward = core_camera.getForward()
  local lightPos = camPos
    + core_camera.getRight() * CONFIG.offsetHorizontal
    + core_camera.getUp() * CONFIG.offsetVertical
    + forward * CONFIG.offsetForward

  spotLight:setPosition(lightPos)

  local rot = buildLightRotation(lightPos, getCameraAimPoint(camPos, forward), core_camera.getUp())
  if rot then
    spotLight:setField("rotation", 0, rot.x .. " " .. rot.y .. " " .. rot.z .. " " .. rot.w)
  end

  applySpotLightFields(spotLight, shouldLightBeActive())
end

local function endPulse()
  M.capturePulseActive = false
  if M.enabled then
    applyLightState()
  end
end

local function finishPulseCapture()
  pendingPulseCapture = nil
  endPulse()
end

local function beginPulseCleanup()
  if not pendingPulseCapture then
    return
  end

  pendingPulseCapture.awaitingScreenshotDone = false
  pendingPulseCapture.fallbackFramesRemaining = nil
  pendingPulseCapture.cleanupFramesRemaining = CONFIG.pulseCleanupFrames
end

local function dispatchCapture(kind, args)
  local screenshot = require("screenshot")

  if kind == "takeScreenShot" then
    screenshot.takeScreenShot(args[1], args[2], args[3], args[4])
  elseif kind == "takeBigScreenShot" then
    screenshot.takeBigScreenShot(args[1], args[2], args[3], args[4])
  elseif kind == "takeHugeScreenShot" then
    screenshot.takeHugeScreenShot(args[1], args[2], args[3], args[4])
  elseif kind == "takeCustomScreenShot" then
    screenshot.takeCustomScreenShot(args[1], args[2], args[3], args[4], args[5], args[6])
  elseif kind == "takeMotionBlurScreenShot" then
    screenshot.takeMotionBlurScreenShot(args[1], args[2], args[3], args[4], args[5], args[6])
  elseif kind == "publish" then
    screenshot.publish()
  elseif kind == "steam" then
    screenshot.doSteamScreenshot(args[1])
  else
    log("E", logTag, "unknown capture kind: " .. tostring(kind))
  end
end

function M.enable(en)
  en = en == true

  if en == M.enabled and en == (spotLight ~= nil) then
    applyLightState()
    return
  end

  M.enabled = en
  pendingPulseCapture = nil
  M.capturePulseActive = false

  if en then
    if not spotLight and not createSpotLight() then
      M.enabled = false
      return
    end
    applyLightState()
  else
    destroySpotLight()
  end
end

function M.runCapture(kind, ...)
  local args = { ... }

  if not M.enabled then
    dispatchCapture(kind, args)
    return true
  end

  if M.mode == "pulse" then
    if pendingPulseCapture then
      log("W", logTag, "capture ignored: pulse already in progress")
      return false, "capture_busy"
    end

    M.capturePulseActive = true
    pendingPulseCapture = {
      kind = kind,
      args = args,
      warmupFramesRemaining = CONFIG.pulseWarmupFrames,
      awaitingScreenshotDone = false,
      cleanupFramesRemaining = nil,
      fallbackFramesRemaining = nil,
      useScreenshotHook = kind ~= "steam",
    }
    applyLightState()
    return true
  end

  applyLightState()
  local ok, err = pcall(function()
    dispatchCapture(kind, args)
  end)
  if not ok then
    log("E", logTag, "capture failed: " .. tostring(err))
    return false, "screenshot_request_failed"
  end
  return true
end

function M.applyFromUi(enabled, fireOnCapture, intensity, outerAngle, hue, saturation)
  if enabled ~= true then
    M.enable(false)
    return
  end

  M.mode = fireOnCapture == true and "pulse" or "always"
  local intensityN = tonumber(intensity)
  M.intensity = intensityN and math.max(CONFIG.intensityMin, math.min(CONFIG.intensityMax, intensityN)) or CONFIG.intensityDefault
  M.outerAngle = clamp(outerAngle, CONFIG.outerAngleDefault, CONFIG.outerAngleMin, CONFIG.outerAngleMax)
  M.hue = clamp(hue, CONFIG.hueDefault, 0, 360)
  M.saturation = clamp(saturation, CONFIG.saturationDefault, 0, 100)

  M.enable(true)
end

function M.onPreRender(dtReal, dtSim, dtRaw)
  if pendingPulseCapture then
    applyLightState()

    if pendingPulseCapture.warmupFramesRemaining > 0 then
      pendingPulseCapture.warmupFramesRemaining = pendingPulseCapture.warmupFramesRemaining - 1
      if pendingPulseCapture.warmupFramesRemaining > 0 then
        return
      end

      pendingPulseCapture.awaitingScreenshotDone = pendingPulseCapture.useScreenshotHook
      pendingPulseCapture.fallbackFramesRemaining = CONFIG.pulseFallbackFrames

      local ok, err = pcall(function()
        dispatchCapture(pendingPulseCapture.kind, pendingPulseCapture.args)
      end)
      if not ok then
        log("E", logTag, "capture failed: " .. tostring(err))
        finishPulseCapture()
      elseif not pendingPulseCapture.awaitingScreenshotDone then
        beginPulseCleanup()
      end
      return
    end

    if pendingPulseCapture.cleanupFramesRemaining then
      pendingPulseCapture.cleanupFramesRemaining = pendingPulseCapture.cleanupFramesRemaining - 1
      if pendingPulseCapture.cleanupFramesRemaining <= 0 then
        finishPulseCapture()
      end
      return
    end

    if pendingPulseCapture.awaitingScreenshotDone and pendingPulseCapture.fallbackFramesRemaining then
      pendingPulseCapture.fallbackFramesRemaining = pendingPulseCapture.fallbackFramesRemaining - 1
      if pendingPulseCapture.fallbackFramesRemaining <= 0 then
        log("W", logTag, "pulse capture fallback timeout")
        beginPulseCleanup()
      end
    end
    return
  end

  if M.enabled and spotLight then
    applyLightState()
  end
end

function M.onScreenshotAllDone()
  if photoModeOpen ~= true or not pendingPulseCapture or pendingPulseCapture.awaitingScreenshotDone ~= true then
    return
  end

  beginPulseCleanup()
end

function M.onExtensionUnloaded()
  M.enable(false)
end

return M
