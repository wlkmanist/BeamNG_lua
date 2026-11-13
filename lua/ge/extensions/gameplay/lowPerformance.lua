-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Detects a sustained low frame rate in freeroam and split-screen and suggests removing vehicles.
-- Curated content (missions, scenarios, career, tutorials) is never checked, so a slow machine
-- is not mistaken for badly optimized content.

local M = {}

local navigationContext = require("ge/extensions/ui/router/services/navigationContext")

local logTag = "lowPerformance"

local FPS_THRESHOLD = 25
local SMOOTHING_TIME_S = 5
local ENTER_AFTER_S = 5
local EXIT_AFTER_S = 10
local GRACE_PERIOD_S = 5
local MAX_FRAME_DT_S = 0.25 -- longer frames are script/loading stalls, not the steady frame rate
local GATE_CHECK_INTERVAL_S = 1
local FADE_FINISHED_STATE = 3
local NOTIFY_SETTING = "notifyLowPerformance"

local CHECKED_MODES = { freeroam = true, multiseatGamemode = true }

local fpsSmoother = newExponentialSmoothing(2) -- the window is passed per frame in onUpdate
local gateActive = false
local gateCheckTimer = 0
local graceTimer = GRACE_PERIOD_S
local belowTimer = 0
local aboveTimer = 0
local fading = false
local lowPerformance = false
local spawnWarningShown = false
local pendingSpawnFn = nil

local function isGateActive()
  if not getCurrentLevelIdentifier() then return false end
  local context = navigationContext.getContext()
  if not CHECKED_MODES[context.mode] or context.isFirstDriveActive then return false end
  if render_openxr and render_openxr.isSessionRunning() then return false end
  return not (settings.getValue("fpsLimitEnabled") and (tonumber(settings.getValue("fpsLimit")) or 0) <= FPS_THRESHOLD)
end

local function isPlayRoute()
  local route = ui_router and ui_router.getCurrent()
  return route and route.request and route.request.name == "play"
end

local function canSampleFrame()
  return not fading
    and not simTimeAuthority.getPause()
    and Engine.isProgramFocused()
    and not editor.isEditorActive()
    and isPlayRoute()
end

local function restartGracePeriod()
  graceTimer = GRACE_PERIOD_S
  belowTimer = 0
  aboveTimer = 0
end

-- simple menu has no option to mute them
local function notificationsEnabled()
  return Engine.UI.isSimpleMenu() or settings.getValue(NOTIFY_SETTING) ~= false
end

local function enterLowPerformance(fps)
  lowPerformance = true
  spawnWarningShown = false
  -- TODO: consider adding low fps events to telemetry (telemetry_core.addEvent)
  if notificationsEnabled() then
    guihooks.trigger("toastrMsg", {
      type = "warning",
      label = "lowPerformance",
      title = "ui.lowPerformance.toast.title",
      msg = "ui.lowPerformance.hint",
      config = { timeOut = 8000 },
    })
  end
  if not shipping_build then
    log("I", logTag, string.format("Low performance detected, smoothed FPS: %.1f", fps))
  end
end

local function isLowPerformance()
  return lowPerformance and isGateActive()
end

-- Returns spawnFn's result, or false while the player decides on the warning
local function confirmSpawn(spawnFn)
  if spawnWarningShown or not isLowPerformance() or not notificationsEnabled() then return spawnFn() end
  spawnWarningShown = true
  pendingSpawnFn = spawnFn
  local buttons = {
    { label = "ui.common.cancel", luaCallback = "gameplay_lowPerformance.cancelPendingSpawn()", isCancel = true },
  }
  if not Engine.UI.isSimpleMenu() then
    table.insert(buttons, {
      label = "ui.common.doNotShowAgain",
      luaCallback = "gameplay_lowPerformance.muteAndConfirmPendingSpawn()",
    })
  end
  table.insert(buttons, {
    label = "ui.common.continue",
    luaCallback = "gameplay_lowPerformance.confirmPendingSpawn()",
    isConfirm = true,
  })
  guihooks.trigger("showConfirmationDialog", {
    title = "ui.lowPerformance.spawnWarning.title",
    text = "ui.lowPerformance.spawnWarning.message",
    buttons = buttons,
  })
  return false
end

local function confirmPendingSpawn()
  local spawnFn = pendingSpawnFn
  pendingSpawnFn = nil
  if spawnFn then spawnFn() end
end

local function cancelPendingSpawn()
  pendingSpawnFn = nil
end

local function muteAndConfirmPendingSpawn()
  settings.setValue(NOTIFY_SETTING, false)
  guihooks.trigger("toastrMsg", {
    type = "info",
    label = "lowPerformance",
    title = "ui.lowPerformance.notificationsDisabled.title",
    msg = "ui.lowPerformance.notificationsDisabled.message",
    config = { timeOut = 8000 },
  })
  confirmPendingSpawn()
end

local function getPauseNotice()
  if not isLowPerformance() or not notificationsEnabled() then return nil end
  return {
    notice = _tr("ui.lowPerformance.notice"),
    hint = _tr("ui.lowPerformance.hint"),
    infoTitle = _tr("ui.lowPerformance.info.title"),
    infoMessage = _tr("ui.lowPerformance.info.message"),
  }
end

local function onUpdate(dtReal, dtSim, dtRaw)
  gateCheckTimer = gateCheckTimer - dtRaw
  if gateCheckTimer <= 0 then
    gateCheckTimer = GATE_CHECK_INTERVAL_S
    gateActive = isGateActive()
    if not gateActive then
      lowPerformance = false
      restartGracePeriod()
    end
  end
  if not gateActive then return end

  if not canSampleFrame() then
    restartGracePeriod()
    return
  end

  local dt = math.min(dtRaw, MAX_FRAME_DT_S)
  if dt <= 0 then return end
  if graceTimer > 0 then
    graceTimer = graceTimer - dt
    if graceTimer <= 0 then
      local engineAvgFps = tonumber(VariableRegistry.get("$fps::avg", 0)) or 0
      fpsSmoother:set(engineAvgFps > 0 and engineAvgFps or 1 / dt)
    end
    return
  end

  -- weighting each frame by its duration keeps the average equal to frames rendered per second
  local fps = fpsSmoother:getWindow(1 / dt, 2 * SMOOTHING_TIME_S / dt)
  if fps < FPS_THRESHOLD then
    belowTimer = belowTimer + dt
    aboveTimer = 0
    if not lowPerformance and belowTimer >= ENTER_AFTER_S then enterLowPerformance(fps) end
  else
    aboveTimer = aboveTimer + dt
    belowTimer = 0
    if lowPerformance and aboveTimer >= EXIT_AFTER_S then lowPerformance = false end
  end
end

local function onVehicleSpawned()
  restartGracePeriod()
end

local function onScreenFadeState(state)
  fading = state ~= FADE_FINISHED_STATE
end

local debugLoadIterations
local debugLoadResult = 0

local function onDrawDebug(_, _, _, dtRaw)
  --if shipping_build then return end
  local im = ui_imgui
  debugLoadIterations = debugLoadIterations or im.IntPtr(0)
  local context = navigationContext.getContext()
  local route = ui_router and ui_router.getCurrent()
  local routeName = route and route.request and route.request.name or "<none>"
  local levelId = getCurrentLevelIdentifier()
  local fpsLimitEnabled = settings.getValue("fpsLimitEnabled") == true
  local fpsLimit = tonumber(settings.getValue("fpsLimit")) or 0
  local openXR = render_openxr and render_openxr.isSessionRunning() or false
  local paused = simTimeAuthority.getPause()
  local focused = Engine.isProgramFocused()
  local editorActive = editor.isEditorActive()
  local playRoute = isPlayRoute()
  local sampling = canSampleFrame()
  local currentGateActive = isGateActive()
  local smoothedFps = fpsSmoother:value()
  local rawDt = tonumber(dtRaw) or 0
  local frameFps = rawDt > 0 and 1 / rawDt or 0
  local engineAvgFps = tonumber(VariableRegistry.get("$fps::avg", 0)) or 0
  local simpleMenu = Engine.UI.isSimpleMenu()
  local notifySetting = settings.getValue(NOTIFY_SETTING) ~= false

  local phase = "monitoring"
  if not gateActive then
    phase = "gate blocked"
  elseif not sampling then
    phase = "sampling paused"
  elseif graceTimer > 0 then
    phase = "grace period"
  elseif lowPerformance then
    phase = aboveTimer > 0 and "recovering" or "low performance"
  elseif belowTimer > 0 then
    phase = "entering low performance"
  end

  local gateReason = "active"
  if not levelId then
    gateReason = "no level"
  elseif not CHECKED_MODES[context.mode] then
    gateReason = "unchecked mode"
  elseif context.isFirstDriveActive then
    gateReason = "first drive"
  elseif openXR then
    gateReason = "OpenXR"
  elseif fpsLimitEnabled and fpsLimit <= FPS_THRESHOLD then
    gateReason = "FPS limit"
  end

  local function stateText(label, value)
    im.Text(string.format("%-24s %s", label .. ":", tostring(value)))
  end

  local function timerBar(label, value, duration)
    local progress = clamp(value / duration, 0, 1)
    im.Text(label)
    im.ProgressBar(progress, im.ImVec2(-1, 0), string.format("%.2f / %.2f s", value, duration))
  end

  local function summaryText(text)
    im.TextDisabled(text)
  end

  im.SetNextWindowSize(im.ImVec2(430, 620), im.Cond_FirstUseEver)
  if im.Begin("Low Performance Checker Debug") then
    if im.CollapsingHeader1("Artificial load", im.TreeNodeFlags_DefaultOpen) then
      im.SliderInt("Iterations per frame", debugLoadIterations, 0, 10000000, "%d", im.SliderFlags_Logarithmic)
      stateText("Load result", string.format("%.3f", debugLoadResult))
    else
      summaryText(string.format("%d iterations/frame", debugLoadIterations[0]))
    end

    if im.CollapsingHeader1("Detector", im.TreeNodeFlags_DefaultOpen) then
      stateText("Phase", phase)
      stateText("Low performance", lowPerformance)
      stateText("Effective low performance", isLowPerformance())
      stateText("Cached gate active", gateActive)
      stateText("Current gate active", currentGateActive)
      stateText("Gate reason", gateReason)
      stateText("Can sample frame", sampling)
      stateText("Notifications enabled", notificationsEnabled())
      stateText("Spawn warning shown", spawnWarningShown)
      stateText("Pending spawn", pendingSpawnFn ~= nil)
      if im.Button("Restart grace period") then restartGracePeriod() end
      im.SameLine()
      if im.Button("Clear low performance") then lowPerformance = false end
    else
      summaryText(string.format("%s | effective: %s | gate: %s", phase, tostring(isLowPerformance()), gateReason))
    end

    if im.CollapsingHeader1("Frame rate", im.TreeNodeFlags_DefaultOpen) then
      stateText("Current frame FPS", string.format("%.1f", frameFps))
      stateText("Smoothed FPS", string.format("%.1f", smoothedFps))
      stateText("Engine average FPS", string.format("%.1f", engineAvgFps))
      stateText("Raw frame dt", string.format("%.4f s", rawDt))
      stateText("Threshold", string.format("%.1f FPS", FPS_THRESHOLD))
    else
      summaryText(string.format("frame %.1f | smoothed %.1f | threshold %.1f FPS", frameFps, smoothedFps, FPS_THRESHOLD))
    end

    if im.CollapsingHeader1("Timers", im.TreeNodeFlags_DefaultOpen) then
      timerBar("Grace remaining", math.max(graceTimer, 0), GRACE_PERIOD_S)
      timerBar("Below-threshold dwell", belowTimer, ENTER_AFTER_S)
      timerBar("Above-threshold dwell", aboveTimer, EXIT_AFTER_S)
      timerBar("Gate check remaining", math.max(gateCheckTimer, 0), GATE_CHECK_INTERVAL_S)
    else
      summaryText(string.format("grace %.1fs | below %.1fs | above %.1fs", math.max(graceTimer, 0), belowTimer, aboveTimer))
    end

    if im.CollapsingHeader1("Environment", im.TreeNodeFlags_DefaultOpen) then
      stateText("Level", levelId or "<none>")
      stateText("Mode", context.mode)
      stateText("Route", routeName)
      stateText("Checked mode", CHECKED_MODES[context.mode] == true)
      stateText("First drive", context.isFirstDriveActive)
      stateText("OpenXR", openXR)
      stateText("Paused", paused)
      stateText("Focused", focused)
      stateText("Editor active", editorActive)
      stateText("Fading", fading)
      stateText("Play route", playRoute)
      stateText("Simple menu", simpleMenu)
      stateText("Notification setting", notifySetting)
      stateText("FPS limit enabled", fpsLimitEnabled)
      stateText("FPS limit", fpsLimit)
    else
      summaryText(string.format("%s | %s | sampling: %s", context.mode, routeName, tostring(sampling)))
    end

    if im.CollapsingHeader1("Configuration", im.TreeNodeFlags_DefaultOpen) then
      stateText("Smoothing time", SMOOTHING_TIME_S .. " s")
      stateText("Enter after", ENTER_AFTER_S .. " s")
      stateText("Exit after", EXIT_AFTER_S .. " s")
      stateText("Grace period", GRACE_PERIOD_S .. " s")
      stateText("Maximum sampled dt", MAX_FRAME_DT_S .. " s")
    else
      summaryText(string.format("%.0f FPS | enter %.0fs | exit %.0fs", FPS_THRESHOLD, ENTER_AFTER_S, EXIT_AFTER_S))
    end
  end
  im.End()

  local loadResult = debugLoadResult
  for i = 1, debugLoadIterations[0] do
    loadResult = (loadResult + i * 0.000001) % 1000
  end
  debugLoadResult = loadResult
end

M.onUpdate = onUpdate
M.onVehicleSpawned = onVehicleSpawned
M.onScreenFadeState = onScreenFadeState
--M.onDrawDebug = onDrawDebug -- Comment out this line to disable the debug window completely.

M.isLowPerformance = isLowPerformance
M.confirmSpawn = confirmSpawn
M.confirmPendingSpawn = confirmPendingSpawn
M.cancelPendingSpawn = cancelPendingSpawn
M.muteAndConfirmPendingSpawn = muteAndConfirmPendingSpawn
M.getPauseNotice = getPauseNotice

return M
