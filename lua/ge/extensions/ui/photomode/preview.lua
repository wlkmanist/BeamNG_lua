-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {
  "ui_photomode_shared",
  "ui_photomode_camera",
  "ui_photomode_scene",
  "ui_photomode_effects",
  "ui_photomode_advancedRender",
  "ui_photomode_capture",
  "ui_photomode_presets",
}


local function buildPreviewPlaybackPayload(openMap)
  if type(openMap) ~= "table" then
    return nil, "preview_metadata_invalid"
  end

  local level = tostring(openMap.level or "")
  if level == "" then
    return nil, "preview_level_missing"
  end

  local payload = {
    level = level,
  }

  local camPos = ui_photomode_shared.normalizePreviewNumberArray(openMap.camPos, 3)
  if camPos then
    payload.camPos = camPos
  end

  local camRot = ui_photomode_shared.normalizePreviewNumberArray(openMap.camRot, 4)
  if camRot then
    payload.camRot = camRot
  end

  local fov = tonumber(openMap.fov)
  if fov and fov > 0 then
    payload.fov = fov
  end

  local timeOfDay = tonumber(openMap.timeOfDay)
  if timeOfDay ~= nil then
    payload.timeOfDay = timeOfDay
  end

  return payload
end

local function runPreviewJumpPayload(payload)
  if commands and type(commands.setFreeCamera) == "function" then
    local freecamOk, freecamErr = pcall(commands.setFreeCamera)
    if not freecamOk then
      log("E", logTag, "runPreviewJumpPayload setFreeCamera failed: " .. tostring(freecamErr))
    end
  end

  if payload.camPos then
    local setPosRot = ui_photomode_shared.getCoreCameraFunction("setPosRot")
    if not setPosRot then
      return false, "camera_api_unavailable"
    end

    local camRot = payload.camRot or {}
    local setPosOk, setPosErr = pcall(
      setPosRot,
      0,
      payload.camPos[1],
      payload.camPos[2],
      payload.camPos[3],
      camRot[1],
      camRot[2],
      camRot[3],
      camRot[4]
    )
    if not setPosOk then
      log("E", logTag, "runPreviewJumpPayload setPosRot failed: " .. tostring(setPosErr))
      return false, "camera_set_failed"
    end
  end

  if payload.fov then
    local setFOV = ui_photomode_shared.getCoreCameraFunction("setFOV")
    if setFOV then
      local setFovOk, setFovErr = pcall(setFOV, 0, payload.fov)
      if not setFovOk then
        log("E", logTag, "runPreviewJumpPayload setFOV failed: " .. tostring(setFovErr))
      end
    end
  end

  if payload.timeOfDay ~= nil and core_environment and type(core_environment.setTimeOfDay) == "function" then
    local timeOk, timeErr = pcall(core_environment.setTimeOfDay, { time = payload.timeOfDay })
    if not timeOk then
      log("E", logTag, "runPreviewJumpPayload setTimeOfDay failed: " .. tostring(timeErr))
    end
  end

  return true
end

local function dispatchPreviewCrossLevelPayload(payload)
  if not extensions or type(extensions.load) ~= "function" then
    log("E", logTag, "playPreviewFromMetadata failed: extensions.load unavailable")
    return false, "extensions_load_unavailable"
  end

  local loadOk, loadErr = pcall(extensions.load, "core_loadMapCmd")
  if not loadOk then
    log("E", logTag, "playPreviewFromMetadata loadMapCmd load failed: " .. tostring(loadErr))
    return false, "loadMapCmd_load_failed"
  end

  if type(setExtensionUnloadMode) == "function" then
    local unloadModeOk, unloadModeErr = pcall(setExtensionUnloadMode, "core_loadMapCmd", "manual")
    if not unloadModeOk then
      log("W", logTag, "playPreviewFromMetadata setExtensionUnloadMode failed: " .. tostring(unloadModeErr))
    end
  end

  local loadMapCmd = extensions and extensions.core_loadMapCmd or nil
  if not loadMapCmd or type(loadMapCmd.set) ~= "function" then
    log("E", logTag, "playPreviewFromMetadata failed: core_loadMapCmd.set unavailable")
    return false, "loadMapCmd_unavailable"
  end

  local setOk, setErr = pcall(loadMapCmd.set, payload, false)
  if not setOk then
    log("E", logTag, "playPreviewFromMetadata loadMapCmd.set failed: " .. tostring(setErr))
    return false, "loadMapCmd_set_failed"
  end

  ui_photomode_shared.logDebug("playPreviewFromMetadata dispatched cross-level payload")
  return true
end

local function tryRunPendingPreviewPlayback()
  local payload = ui_photomode_shared.S.pendingPreviewPlayback
  if type(payload) ~= "table" then
    return
  end

  if ui_photomode_shared.S.sessionActive then
    return
  end

  local stateName = core_gamestate and core_gamestate.state and tostring(core_gamestate.state.state or "") or ""
  if stateName == "" or stateName == "menu" then
    return
  end

  local currentLevel = type(getMissionFilename) == "function" and tostring(getMissionFilename() or "") or ""
  if currentLevel == "" then
    return
  end

  if ui_photomode_shared.normalizePathForCompare(currentLevel) == ui_photomode_shared.normalizePathForCompare(payload.level) then
    local jumpOk, jumpReason = runPreviewJumpPayload(payload)
    if not jumpOk then
      log("E", logTag, "playPreviewFromMetadata same-level jump failed: " .. tostring(jumpReason))
      return
    end
    ui_photomode_shared.S.pendingPreviewPlayback = nil
    ui_photomode_shared.logDebug("playPreviewFromMetadata applied same-level payload")
    return
  end

  local dispatchOk = dispatchPreviewCrossLevelPayload(payload)
  if not dispatchOk then
    return
  end

  ui_photomode_shared.S.pendingPreviewPlayback = nil
end


local function buildPhotomodeMetadataState()
  if not ui_photomode_shared.S.sessionActive then
    return nil
  end
  return {
    schemaVersion = ui_photomode_shared.S.photomodeMetadataStateVersion,
    camera = ui_photomode_camera.buildMetadataState(),
    scene = ui_photomode_scene.buildMetadataState(),
    effects = ui_photomode_effects.buildMetadataState(),
    advancedRender = ui_photomode_advancedRender.buildMetadataState(),
    capture = ui_photomode_capture.buildMetadataState(),
  }
end

function M.openPreviewShareUrl(shareUrl)
  shareUrl = tostring(shareUrl or "")
  if shareUrl == "" then
    return {
      ok = false,
      reason = "share_url_missing",
    }
  end

  local openShareUrlAction = ui_photomode_shared.buildMediaActions().preview.openShareUrl
  if not openShareUrlAction or openShareUrlAction.enabled ~= true then
    return {
      ok = false,
      reason = openShareUrlAction and openShareUrlAction.reason or "browser_unavailable",
    }
  end

  local openOk, openError = pcall(openWebBrowser, shareUrl)
  if not openOk then
    log("E", logTag, "openPreviewShareUrl failed: " .. tostring(openError))
    return {
      ok = false,
      reason = "open_web_failed",
    }
  end

  return {
    ok = true,
  }
end

function M.collectScreenshotMetadata(metadata)
  if type(metadata) ~= "table" or not ui_photomode_shared.S.sessionActive then
    return
  end

  local photomodeState = buildPhotomodeMetadataState()
  if type(photomodeState) ~= "table" then
    return
  end

  metadata.photomodeState = photomodeState
  metadata.photomodePresets = ui_photomode_presets.getScreenshotPresetBundle()
end


function M.playPreviewFromMetadata(openMap)
  if not ui_photomode_shared.S.sessionActive then
    return {
      ok = false,
      reason = "session_inactive",
    }
  end

  local payload, reason = buildPreviewPlaybackPayload(openMap)
  if not payload then
    return {
      ok = false,
      reason = reason or "preview_metadata_invalid",
    }
  end

  local currentLevel = type(getMissionFilename) == "function" and tostring(getMissionFilename() or "") or ""
  local isSameLevel = currentLevel ~= ""
    and ui_photomode_shared.normalizePathForCompare(currentLevel) == ui_photomode_shared.normalizePathForCompare(payload.level)

  if not isSameLevel then
    local dispatchOk, dispatchReason = dispatchPreviewCrossLevelPayload(payload)
    if not dispatchOk then
      return {
        ok = false,
        reason = dispatchReason or "preview_cross_level_dispatch_failed",
      }
    end

    return {
      ok = true,
      level = payload.level,
      requiresGameStatePlay = true,
    }
  end

  ui_photomode_shared.S.pendingPreviewPlayback = payload
  return {
    ok = true,
    level = payload.level,
    requiresGameStatePlay = true,
  }
end


function M.handleUpdate(dtReal, dtSim, dtRaw)
  tryRunPendingPreviewPlayback()
end


return M
