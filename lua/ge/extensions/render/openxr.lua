-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local unknownSystemName = "?"

local im = ui_imgui
local debugWindowOpen = im.BoolPtr(false)
local debugWindowSize = im.ImVec2(0, 0)

local welcomeTitle     = "ui.openXR.welcomeTitle"
local welcomeBody      = "ui.openXR.welcomeBody"
local buttonOkText     = "ui.openXR.buttonOkText"
local buttonNoVulkanText="ui.openXR.buttonNoVulkanText"
local buttonCancelText = "ui.openXR.buttonCancelText"
local buttonOkLua     = "extensions.render_openxr.closeWelcome(true)"
local buttonNoVulkanLua="extensions.render_openxr.closeWelcome(false)"
local buttonCancelLua = "extensions.render_openxr.closeWelcome(false)"

local M = {}
M.dependencies = { "core_camera" } -- ensure execution order against camera VR corrections, to avoid a one-frame pose latency
M.stateString = "disabled" -- can also be "enabled" and "welcome"
M.cefDialogOpen = nil
M.state = {}
M.state.systemName = unknownSystemName

local pointerSettings = {
  { key = "openXRuiEnabled", field = "openXRuiEnabled", ctor = im.BoolPtr },
  { key = "openXRuiMode", field = "openXRuiMode", ctor = im.IntPtr },
  { key = "openXRwindowViewMode", field = "openXRwindowViewMode", ctor = im.IntPtr },
  { key = "openXRdebugEnabled", field = "openXRdebugEnabled", ctor = im.BoolPtr },
  { key = "openXRquadCompositionEnabled", field = "openXRquadCompositionEnabled", ctor = im.BoolPtr, default = false },
}

local variableOnUpdate = nop
local function onPreRender(...)
  variableOnUpdate(...)
end

local function logState()
    log("D", "", "Current OpenXR state: "..dumps(M.state))
end

--[[ TODO
local inputSourceStateCache = nil
local sourcePoseCache = {}
local function getInputSourceStates()
  local sources = inputSourceStateCache
  if sources then
    return sources
  end

  sources = OpenXR.getInputSourceStates()
  inputSourceStateCache = sources
  return sources
end

local function getSourcePoseStates(sourcePath)
  local poses = sourcePoseCache[sourcePath]
  if poses or not sourcePath or sourcePath == "" then
    return poses or {}
  end

  poses = {}
  for path, rawPose in pairs(OpenXR.getSourcePoseStates(sourcePath)) do
    local pose = { pos = vec3(), rot = quat() }
    pose.id = rawPose.id
    pose.active = rawPose.active
    pose.poseValid = rawPose.poseValid
    if pose.poseValid then
      pose.pos:set(rawPose.pos.x, rawPose.pos.y, rawPose.pos.z)
      pose.rot:set(rawPose.rot.x, rawPose.rot.y, rawPose.rot.z, rawPose.rot.w)
    end
    poses[path] = pose
  end
  sourcePoseCache[sourcePath] = poses
  return poses
end
--]]
local fieldsTriggeringGuiHook = { "enabled", "sessionRunning", "headsetActive", "systemName", "targetRefreshRate", "renderedWidth", "renderedHeight", "recommendedWidth", "recommendedHeight", "sourceCount", "activeSourceCount", "poseValidSourceCount", "inputSourcesKey" }
local lastKnownUIState = {}
local function updateUI(forced)
  local changed = forced
  for _,triggerField in ipairs(fieldsTriggeringGuiHook) do
    if M.state[triggerField] ~= lastKnownUIState[triggerField] then
      changed = true
      lastKnownUIState[triggerField] = M.state[triggerField]
    end
  end
  if not changed then return end

  if forced then
    logState()
  end
  guihooks.trigger('OpenXRStateChanged', M.state)
end

local function stateChanged(state)
  --TODO inputSourceStateCache = nil
  --TODO sourcePoseCache = {}
  state.currentRefreshRate = state.currentRefreshRate > 1e10 and 0 or state.currentRefreshRate -- skip infinite refresh rates, due to (1/period) when period is unknown (zero)
  state.targetRefreshRate = math.max(M.state.targetRefreshRate or 0, state.currentRefreshRate)

  --[[ TODO
  local activeSourceCount = 0
  local poseValidSourceCount = 0
  local inputSourcesKey = {}
  for _, source in ipairs(state.inputSources) do
    if source.active then activeSourceCount = activeSourceCount + 1 end
    if source.poseValid then poseValidSourceCount = poseValidSourceCount + 1 end
    inputSourcesKey[#inputSourcesKey + 1] = string.format("%s|%s|%d|%d", source.path, source.interactionProfile, source.active and 1 or 0, source.poseValid and 1 or 0)
  end
  state.sourceCount = #state.inputSources
  state.activeSourceCount = activeSourceCount
  state.poseValidSourceCount = poseValidSourceCount
  state.inputSourcesKey = table.concat(inputSourcesKey, "\n")
  inputSourceStateCache = state.inputSources
  --]]

  M.state = state
  if M.state.enabled and M.stateString ~= "enabled" then M.setStateUI("enabled") end
  if not M.state.enabled and M.stateString == "enabled" then M.setStateUI("disabled") end
  debugWindowOpen[0] = M.state.enabled
  updateUI()
end

local function saveSettings()
  for _, setting in ipairs(pointerSettings) do
    settings.setValue(setting.key, M[setting.field][0])
  end
end

local function loadPointerSettings()
  for _, setting in ipairs(pointerSettings) do
    local value = settings.getValue(setting.key)
    if value == nil then
      value = setting.default
    end
    M[setting.field] = setting.ctor(value)
  end
end

local function onSettingsChanged()
  local previousDebugEnabled = M.openXRdebugEnabled and M.openXRdebugEnabled[0]

  M.openXRimguiEnabled = settings.getValue("openXRimguiEnabled")
  loadPointerSettings()

  if previousDebugEnabled ~= M.openXRdebugEnabled[0] and M.state and M.state.sessionRunning then
    M.restart()
  end
  if OpenXR.getEnable() then
    OpenXR.generateUiCurvature() -- will use those settings we just got
  end
end

local function onInit()
  setExtensionUnloadMode(M, "manual")
  onSettingsChanged()
end

local function closeWelcome(enable)
  M.cefDialogOpen = nil
  M.setStateUI(enable and "enabled" or "disabled")
end

--[[ TODO
-- Small example of how to access controller data
local solidTmp = ColorF(0, 0, 0, 1)
local function solid(c, alpha) solidTmp.r = c.r solidTmp.g = c.g solidTmp.b = c.b solidTmp.a = alpha or 1 return solidTmp end
local tmp = vec3()
local fwd, up = vec3(0, 1, 0), vec3(0, 0, 1)
local colorWhiteI = ColorI(255, 255, 255, 255)
local colorGrayF = ColorF(0.45, 0.45, 0.45, 1)
local colorOrangeF = ColorF(1, 0.5, 0, 1)
local colorBlackF = ColorF(0, 0, 0, 1)
local posePathPriority = { "/input/aim/pose", "/input/grip/pose", "/input/palm_ext/pose" }
local defaultExamplePose = { pos = vec3(), rot = quat(), active = false, poseValid = false }
local function getExamplePoseState(sourcePath)
  local poses = M.getSourcePoseStates(sourcePath)
  for _, path in ipairs(posePathPriority) do
    local pose = poses[path]
    if pose and pose.poseValid then
      return path, pose
    end
  end
  for path, pose in pairs(poses) do
    if pose.poseValid then
      return path, pose
    end
  end
  for path, pose in pairs(poses) do
    return path, pose
  end
  return nil, defaultExamplePose
end

local function sourceExample()
  for _, source in ipairs(M.getInputSourceStates()) do
    local posePath, v = getExamplePoseState(source.path)
    local c = v.active and colorOrangeF or colorGrayF
    debugDrawer:drawSphere(v.pos, 0.03, solid(c, v.poseValid and 0.85 or 0.05))
    tmp:setRotate(v.rot, fwd) tmp:setAddScaled(v.pos, tmp, 0.25) debugDrawer:drawCylinder(v.pos, tmp, 0.01, solid(colorBlackF, v.poseValid and 0.25 or 0.05))
    tmp:setRotate(v.rot, up) tmp:setAddScaled(v.pos, tmp, 0.04) debugDrawer:drawCylinder(v.pos, tmp, 0.02, solid(colorBlackF, v.poseValid and 0.25 or 0.05))
    tmp:setAddScaled(v.pos, up, 0.08)
    local label = string.format("%s %s %s", source.path, posePath or "no_pose", not v.active and "inactive" or not v.poseValid and "no pose" or "ready")
    debugDrawer:drawTextAdvanced(tmp, label, c, true, false, colorWhiteI, true, false, colorBlackF)
  end
end
--]]
local logStatePending = false
local function onUpdate(dtReal, dtSim, dtRaw)
  if logStatePending then
    logStatePending = false
    logState()
  end

  if not M.state.sessionRunning then return end
  --TODO inputSourceStateCache = nil
  --TODO sourcePoseCache = {}
  --TODO sourceExample() -- simplistic example for modders on how to access source state -- not yet implemented, not enough hours in the day to finalize a future-proof API design/implementation/optimization yet :(
  if not M.openXRimguiEnabled then return end

  im.SetNextWindowSize(debugWindowSize --[[, im.Cond_FirstUseEver--]] )
  im.Begin("OpenXR debug tools##openXRwindow", debugWindowOpen)
  if debugWindowOpen[0] == false then
    -- user closed the OpenXR window: we interpret this as wanting to shut down OpenXR for now
    M.setStateUI("disabled")
  else
    -- OpenXR is active: draw the dev UI
    local changed = false

    if im.Button("Turn on/off (ctrl+numpad0)##openXRclose") then
      M.setStateUI("disabled")
    end
    im.SameLine()
    if im.Button("Center (ctrl+numpad5)##openXRcenter") then
      M.center()
    end

    changed = im.Combo2("2D screen view##openXRwindowViewMode", M.openXRwindowViewMode, "Empty (fastest)\0Between eyes (slowest)\0Reuse left eye\0Reuse right eye\0") or changed
    changed = im.Checkbox("Display user interface (CEF)", M.openXRuiEnabled) or changed
    im.Text("   ") im.SameLine()
    --changed = im.Combo2("Anchor##openXRuiMode", M.openXRuiMode, "Room\0Head\0Vehicle (NI)\0Level (NI)\0") or changed -- hide not implemented modes for now
    changed = im.Combo2("Anchor##openXRuiMode", M.openXRuiMode, "Room\0Head") or changed
    if im.Checkbox("UseQuadComposition", M.openXRquadCompositionEnabled) then
      changed = true
      OpenXR.setUseQuadComposition(M.openXRquadCompositionEnabled[0])
    end
    local restartNeeded = false
    restartNeeded = im.Checkbox("Enable debug mode (reduced framerate, will restart OpenXR)", M.openXRdebugEnabled) or restartNeeded
    changed = changed or restartNeeded

    im.Separator()
    im.Text("System name: \"%s\"", M.state.systemName)
    im.Text("   Rendered resolution: %.0fx%.0f", M.state.renderedWidth, M.state.renderedHeight)
    im.Text("   Recommended resolution: %.0fx%.0f", M.state.recommendedWidth, M.state.recommendedHeight)
    im.Text("   Supported resolution: %.0fx%.0f", M.state.supportedWidth, M.state.supportedHeight)
    im.Text("   Supported layers: %.0f", M.state.supportedLayers)
    im.Text("   XrSessionState = \"%s\"", M.state.sessionState)
    im.Text("FOV: left %.3fx%.2f, right %.3fx%.2f (rendered)", M.state.fov0hz, M.state.fov0vt, M.state.fov1hz, M.state.fov1vt)
    im.Text("IPD: %.3f mm", M.state.ipd * 1000)
    --TODO im.Text("Input sources: %d total, %d active, %d pose-valid", M.state.sourceCount or 0, M.state.activeSourceCount or 0, M.state.poseValidSourceCount or 0)

    if changed then
      saveSettings()
    end
    if restartNeeded then
      M.restart()
    end

  end
  im.End()
end

local function restart()
  M.setStateUI("disabled")
  M.setStateUI("enabled")
end

local function closeWelcomeDialog()
  if not M.cefDialogOpen then
    return
  end
  M.cefDialogOpen = nil
  guihooks.trigger('ConfirmationDialogClose', welcomeTitle)
end

M.setStateUI = function(stateString)
  M.stateString = stateString
  variableOnUpdate = nop
  if stateString == "welcome" then
    M.cefDialogOpen = true
    if Engine.Render.getAdapterType() == "Vulkan" then
      guihooks.trigger('ConfirmationDialogOpen', welcomeTitle, welcomeBody, buttonOkText, buttonOkLua, buttonCancelText, buttonCancelLua)
    else
      guihooks.trigger('ConfirmationDialogOpen', welcomeTitle, welcomeBody, nil, nil, buttonNoVulkanText, buttonNoVulkanLua)
    end
  elseif stateString == "enabled" then
    closeWelcomeDialog()
    OpenXR.setEnable(true)
    if OpenXR.getEnable() then
      logStatePending = true
      variableOnUpdate = onUpdate
    else
      log("D", "", "Unable to enable OpenXR") -- all error details should have been logged already by C++ side, no need to throw more Error level logs here, leave as Debug
      M.setStateUI("disabled")
    end
  elseif stateString == "disabled" then
    closeWelcomeDialog()
    OpenXR.setEnable(false)
    extensions.unload(M)
  else
    log("E", "", "Unknown requested stateString: "..dumps(stateString)..". Disabling...")
    M.setStateUI("disabled")
  end
end

local function toggle()
  if     M.stateString == "disabled" then M.setStateUI("welcome")
  elseif M.stateString == "welcome"  then M.setStateUI("enabled")
  else                                    M.setStateUI("disabled")
  end
end

local function center(value)
  if value == nil then
    OpenXR.centerNow()
    return
  end
  OpenXR.centerContinuous(value > 0.2)
end

local function isSessionRunning()
  return M.state and M.state.sessionRunning or false
end

local function errorDetected(err)
  log("E", "", "An OpenXR error was detected with error ID: "..dumps(err))
  local translationId
  if not err then
    translationId = "unkown"
    log("E", "", "An OpenXR error was detected, but no error ID was provided")
  end
  if type(err) ~= "string" then
    translationId = "unkownType"
    log("E", "", string.format("An OpenXR error was detected, but a wrong error type was passed: %s ('%s')", type(err), dumps(err)))
  end
  translationId = "ui.openXR.errors."..(translationId or err)
  log("E", "", "openXR error detected: ".._tr(translationId, ""))
  guihooks.trigger("toastrMsg", {type = "error", title = "ui.openXR.errorsTitle", msg = translationId, config = { closeButton = true, timeOut = 0, extendedTimeOut = 0 } })
end

M.onPreRender = onPreRender -- can't run with onUpdate, that's too eary and will use previous frame's camera positions (core_camera runs at preRender so we must too)
M.onInit = onInit
M.onSettingsChanged = onSettingsChanged
M.stateChanged = stateChanged
M.toggle = toggle
M.center = center
M.isSessionRunning = isSessionRunning
--TODO M.getInputSourceStates = getInputSourceStates
--TODO M.getSourcePoseStates = getSourcePoseStates
M.updateUI = updateUI
M.closeWelcome = closeWelcome
M.errorDetected = errorDetected

return M

