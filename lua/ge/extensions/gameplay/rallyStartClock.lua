-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Drives the in-world rally start clocks. Each file in clockTypesDir is one clock type, mods can add more.
-- A clock type module returns a table with:
--   textures = {key = {tag = '@tag', width = w, height = h, clearColor = color()}, ...}
--   findClocks() -> list of {shapeName = displayShape, transform = MatrixF, scale = Point3F?, anchor = SceneObject?}
--   draw(textures, display): draws into textures[key], display = {clock = 'HH:MM:SS', clockSeconds = 0..86399, label = 'SS1',
--     countdown = '15', countdownSeconds = 15 (0 after the start, nil without countdown), semaphore = 'R'|'A'|'G'}
--   getView(clock, startLine, targetPos) -> direction, distance?, shift? (optional): picture-in-picture camera, placed at
--     targetPos + direction * distance and yawed so the clock sits shift half view widths right of center

local M = {}
local logTag = 'rallyStartClock'
local renderViewBobbing = require('core/cameraModes/bobbing')()

renderViewBobbing.walkBobScale = 0
renderViewBobbing.standingBobScale = 1

local clockTypesDir = '/lua/ge/extensions/gameplay/rally/startClocks/'
local displayGroupName = 'rallyStartClockDisplays'
local renderViewName = 'rallyStartClockView'
local renderViewWidthRatio = 0.2
local renderViewAspectRatio = 400 / 164
local renderViewTopRatio = 0.132
local renderViewMask = 29
local renderViewBorderWidthRatio = 8 / 1920
local renderViewFov = 25
local defaultViewDistance = 1
local defaultViewShift = 1 / 3
local renderViewLingerDuration = 1.5
local goDisplayDuration = 6
local clockSearchRadiusSq = 20 * 20

local semaphoreBorderColors = {
  R = ColorF(1, 30 / 255, 15 / 255, 1),
  A = ColorF(1, 145 / 255, 0, 1),
  G = ColorF(43 / 255, 1, 0, 1),
}

local clockTypes = {}
local activeTypes = {}
local clocks = {}
local displayGroup
local display = {}
local clockSeconds
local clockFresh = false
local launchSeconds
local countdownUiActive = false
local scanTimer = 0
local rebindTimer = 0
local rebindAttempts = 0
local lastDisplay
local renderView
local renderViewClock
local renderViewTargetPos
local renderViewCameraDirection
local renderViewDistance
local renderViewShift
local renderViewAvailable = false
local renderViewPending = false
local renderViewLingerTimer = 0
local renderViewBorderColor = semaphoreBorderColors.R
local renderViewBorderWidth = 1
local renderViewBorderPoints
local renderViewCameraData = {res = {}}

local function loadClockTypes()
  table.clear(clockTypes)
  local files = FS:findFiles(clockTypesDir, '*.lua', 0)
  table.sort(files)
  for _, file in ipairs(files) do
    local modulePath = file:sub(1, -5)
    package.loaded[modulePath] = nil
    local ok, clockType = pcall(require, modulePath)
    if ok and type(clockType) == 'table' and clockType.textures and clockType.findClocks and clockType.draw then
      table.insert(clockTypes, {name = modulePath:match('[^/]+$'), module = clockType})
    else
      log('E', logTag, 'Invalid start clock type ' .. file .. ': ' .. tostring(clockType))
    end
  end
end

local function setRenderViewAvailable(available)
  renderViewAvailable = available
end

local function disableRenderView()
  if renderView then
    renderView.active = false
    renderView.compositeRect = RectI(0, 0, 0, 0)
  end
  renderViewClock = nil
  renderViewTargetPos = nil
  renderViewCameraDirection = nil
  renderViewBorderPoints = nil
  renderViewPending = false
  setRenderViewAvailable(false)
end

local function clocksAreValid()
  if not displayGroup or not simObjectExists(displayGroup) or #clocks == 0 then return false end
  for _, clock in ipairs(clocks) do
    if not simObjectExists(clock.display) or (clock.anchor and not simObjectExists(clock.anchor)) then return false end
  end
  return true
end

local function bindTextures(entry, unbind)
  local bound = true
  for key, texture in pairs(entry.textures) do
    local tag = entry.clockType.textures[key].tag
    local tagBound = false
    for _, clock in ipairs(entry.clocks) do
      if simObjectExists(clock.display) then
        local success
        if unbind then
          success = clock.display:clearTaggedTexture(tag)
        else
          success = clock.display:setTaggedTextureDrawPrim(tag, texture)
        end
        tagBound = success or tagBound
      end
    end
    bound = bound and tagBound
  end
  return bound
end

local function clearClocks()
  disableRenderView()
  for _, entry in ipairs(activeTypes) do
    bindTextures(entry, true)
    for key in pairs(entry.textures) do
      TextureDrawPrimitiveRegistry:removeName(entry.textureNames[key])
    end
  end
  table.clear(activeTypes)
  table.clear(clocks)
  if displayGroup and simObjectExists(displayGroup) then displayGroup:delete() end
  displayGroup = nil
  rebindTimer = 0
  rebindAttempts = 0
  lastDisplay = nil
end

local function createDisplay(clock)
  local object = createObject('TSStatic')
  object.canSave = false
  object.dynamic = true
  object.useInstanceRenderData = true
  object:setField('shapeName', 0, clock.shapeName)
  object:setField('collisionType', 0, 'None')
  object:setField('decalType', 0, 'None')
  if clock.scale then object.scale = clock.scale end
  object:registerObject(Sim.getUniqueName('rallyStartClockDisplay' .. (#clocks + 1)))
  displayGroup:addObject(object)
  object:setTransform(clock.transform)
  return object
end

local function createTextures(entry)
  for key, spec in pairs(entry.clockType.textures) do
    local name = 'rallyStartClock_' .. entry.name .. '_' .. key
    local texture = TextureDrawPrimitiveRegistry:getOrCreate(name, spec.width, spec.height)
    if not texture then return false end
    texture:setClearColor(spec.clearColor)
    texture:setClearFlag('WhenDirty')
    entry.textures[key] = texture
    entry.textureNames[key] = name
  end
  return true
end

local function setupClocks()
  clearClocks()
  if not TextureDrawPrimitiveRegistry then return false end

  for _, clockType in ipairs(clockTypes) do
    local found = clockType.module.findClocks()
    if found and found[1] then
      table.insert(activeTypes, {name = clockType.name, clockType = clockType.module, clocks = found, textures = {}, textureNames = {}})
    end
  end
  if not activeTypes[1] then return false end

  displayGroup = createObject('SimGroup')
  displayGroup.canSave = false
  displayGroup:registerObject(displayGroupName)
  scenetree.MissionGroup:addObject(displayGroup)

  for _, entry in ipairs(activeTypes) do
    for _, clock in ipairs(entry.clocks) do
      clock.clockType = entry.clockType
      clock.display = createDisplay(clock)
      table.insert(clocks, clock)
    end
    if not createTextures(entry) then
      clearClocks()
      return false
    end
    if not bindTextures(entry) then
      log('D', logTag, 'Textures of start clock type ' .. entry.name .. ' not bound yet, retrying')
    end
  end
  rebindAttempts = 4
  rebindTimer = 0.5
  return true
end

local function findStageClock()
  local rallyManager = gameplay_rally and gameplay_rally.getRallyManager and gameplay_rally.getRallyManager()
  local startLine = rallyManager and rallyManager:getSSStartLinePos()
  if not startLine or not startLine.pos then return end

  local startPos = vec3(startLine.pos)
  local closestClock
  local closestDistanceSq = clockSearchRadiusSq
  for _, clock in ipairs(clocks) do
    local object = clock.anchor or clock.display
    if simObjectExists(object) then
      local distanceSq = startPos:squaredDistance(object:getPosition())
      if distanceSq <= closestDistanceSq then
        closestClock = clock
        closestDistanceSq = distanceSq
      end
    end
  end

  if not closestClock then return end

  local targetPos = closestClock.display:getWorldBox():getCenter()
  local cameraDirection, distance, shift
  if closestClock.clockType.getView then
    cameraDirection, distance, shift = closestClock.clockType.getView(closestClock, startLine, targetPos)
  end
  if not cameraDirection then
    cameraDirection = startPos - targetPos
    cameraDirection.z = 0
  end
  if cameraDirection:squaredLength() < 0.01 then return closestClock, targetPos end
  return closestClock, targetPos, cameraDirection:normalized(), distance or defaultViewDistance, shift or defaultViewShift
end

local function getRenderViewRect()
  local canvas = scenetree.findObject('Canvas')
  if not canvas or not canvas.getWindowClientSizeXY then return end

  local windowWidth, windowHeight = canvas:getWindowClientSizeXY()
  if not windowWidth or not windowHeight then return end
  renderViewBorderWidth = math.max(1, windowWidth * renderViewBorderWidthRatio)
  local width = math.floor(windowWidth * renderViewWidthRatio + 0.5)
  local height = math.floor(width / renderViewAspectRatio + 0.5)
  local x = math.floor((windowWidth - width) * 0.5 + 0.5)
  local y = math.floor(windowHeight * renderViewTopRatio + 0.5)
  if width < 2 or height < 2 then return end
  return x, y, width, height
end

local function ensureRenderView(x, y, width, height)
  if not RenderViewManagerInstance then return end
  if not renderView then
    renderView = RenderViewManagerInstance:getOrCreateView(renderViewName)
    if not renderView then return end

    renderView.active = false
    renderView.luaOwned = true
    renderView.namedTexTargetColor = renderViewName
    renderView.renderCubemap = false
    renderView.renderEditorIcons = false
    renderView.renderEditorGizmo = false
    renderView.renderShadows = true
    renderView.usePostEffects = true
    renderView.objectTypeBlacklistMask = 0
    renderView.shadowCasterObjectTypeBlacklistMask = 0
    renderView:maskSet(renderViewMask)

    if RenderSettings then
      local renderSettings = RenderSettings.getGlobals()
      renderSettings.vehicleMirrorsEnabled = false
      renderView.settingsOverride = renderSettings
      renderView.settingsOverrideEnabled = true
    end
  end

  renderView.resolution = Point2I(width, height)
  renderView.viewPort = RectI(0, 0, width, height)
  renderView.compositeRect = RectI(x, y, width, height)

  local mainView = RenderViewManagerInstance:getView('main')
  if mainView then renderView.currentExposure = mainView.currentExposure end
  return renderView
end

local function updateRenderView(dtSim)
  if settings.getValue('rallyStartCountdownDisplay') ~= '3d' or (not countdownUiActive and renderViewLingerTimer <= 0) or not clocksAreValid() then
    disableRenderView()
    return
  end

  if not renderViewClock then
    renderViewClock, renderViewTargetPos, renderViewCameraDirection, renderViewDistance, renderViewShift = findStageClock()
  end
  if not renderViewClock or not simObjectExists(renderViewClock.display) or not renderViewTargetPos or not renderViewCameraDirection then
    disableRenderView()
    return
  end

  local x, y, width, height = getRenderViewRect()
  local view = x and ensureRenderView(x, y, width, height)
  if not view then
    disableRenderView()
    return
  end

  local targetPos = renderViewTargetPos
  local cameraPos = targetPos + renderViewCameraDirection * renderViewDistance
  local viewDirection = targetPos - cameraPos
  local viewRight = viewDirection:cross(vec3(0, 0, 1)):normalized()
  local horizontalHalfWidth = math.tan(math.rad(renderViewFov * 0.5)) * renderViewDistance * width / height
  local lookTarget = targetPos - viewRight * horizontalHalfWidth * renderViewShift
  local cameraRotation = quatFromDir(lookTarget - cameraPos, vec3(0, 0, 1))
  renderViewCameraData.res.pos = cameraPos
  renderViewCameraData.res.rot = cameraRotation
  renderViewBobbing:update(renderViewCameraData, 0, dtSim)
  cameraPos = renderViewCameraData.res.pos
  cameraRotation = renderViewCameraData.res.rot

  local forward = cameraRotation * vec3(0, 1, 0)
  local up = cameraRotation * vec3(0, 0, 1)
  local right = forward:cross(up):normalized()
  local borderDistance = 0.11
  local borderCenter = cameraPos + forward * borderDistance
  local halfHeight = math.tan(math.rad(renderViewFov * 0.5)) * borderDistance
  local halfWidth = halfHeight * width / height
  renderViewBorderPoints = {
    borderCenter - right * halfWidth + up * halfHeight,
    borderCenter + right * halfWidth + up * halfHeight,
    borderCenter + right * halfWidth - up * halfHeight,
    borderCenter - right * halfWidth - up * halfHeight,
  }
  local updated = RenderViewManagerInstance:updateViewCamera(
    renderViewName,
    cameraPos.x, cameraPos.y, cameraPos.z,
    cameraRotation.x, cameraRotation.y, cameraRotation.z, cameraRotation.w,
    renderViewFov, 0.1, 200, false, 0
  )
  view.active = updated
  if not updated then
    disableRenderView()
  elseif renderViewPending then
    setRenderViewAvailable(true)
  else
    renderViewPending = true
  end
end

local function getClockSeconds()
  local loopManager = gameplay_rallyLoop and gameplay_rallyLoop.getManager()
  if loopManager then return loopManager:getWallClockTimeSecs() end
  if clockSeconds ~= nil then return clockSeconds end
  local timeOfDay = core_environment.getTimeOfDay()
  if timeOfDay and timeOfDay.time then return ((timeOfDay.time + 0.5) % 1) * 86400 end
end

local function getStageDisplay()
  local loopManager = gameplay_rallyLoop and gameplay_rallyLoop.getManager()
  if loopManager then
    local schedule = loopManager:getSchedule()
    local entry = schedule and schedule[loopManager.currentMissionIndex]
    if entry and entry.ssLabel then return 'SS' .. tostring(entry.ssLabel):gsub('^SS', '') end
  end
  return 'SS'
end

local function getSecondsUntilLaunch(now)
  return (launchSeconds - now + 43200) % 86400 - 43200
end

local function getCountdownDisplay(now)
  if launchSeconds == nil then return '-', 'R' end

  local remaining = getSecondsUntilLaunch(now)
  if remaining <= 0 then
    local elapsedSeconds = math.floor(-remaining)
    if elapsedSeconds >= goDisplayDuration then return '-', 'R' end
    if elapsedSeconds > 0 then
      return '-' .. math.min(5, elapsedSeconds), 'G', 0
    end
    return '0', 'G', 0
  end

  local semaphoreCode = remaining <= 5 and 'A' or 'R'
  local seconds = math.ceil(remaining)
  if seconds < 60 then
    return tostring(seconds), semaphoreCode, seconds
  end
  return string.format('%d:%02d', math.floor(seconds / 60), seconds % 60), semaphoreCode, seconds
end

local function updateDisplay()
  local now = getClockSeconds()
  if now == nil then return end

  local seconds = math.floor(now) % 86400
  local clockDisplay = string.format('%02d:%02d:%02d', math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
  local stageDisplay = getStageDisplay()
  local countdownDisplay, semaphoreCode, countdownSeconds = getCountdownDisplay(now)
  local displayKey = clockDisplay .. '/' .. stageDisplay .. '/' .. countdownDisplay .. '/' .. semaphoreCode
  if displayKey == lastDisplay then return end

  display.clock = clockDisplay
  display.clockSeconds = seconds
  display.label = stageDisplay
  display.countdown = countdownDisplay
  display.countdownSeconds = countdownSeconds
  display.semaphore = semaphoreCode
  renderViewBorderColor = semaphoreBorderColors[semaphoreCode]
  for _, entry in ipairs(activeTypes) do
    entry.clockType.draw(entry.textures, display)
  end
  lastDisplay = displayKey
end

local function clear()
  disableRenderView()
  if renderView and RenderViewManagerInstance then
    RenderViewManagerInstance:destroyView(renderView)
  end
  renderView = nil
  clearClocks()
  clockSeconds = nil
  launchSeconds = nil
  countdownUiActive = false
  renderViewLingerTimer = 0
  scanTimer = 0
end

function M.onRallyDataUpdated(data)
  if not data then return end

  if data.activeState then
    local hasClockData = data.startClockCountdownData ~= nil or data.rallyClock ~= nil
    if hasClockData or data.activeState ~= 'countdown' then
      local wasActive = countdownUiActive
      countdownUiActive = data.activeState == 'countdown'
      if countdownUiActive then
        renderViewLingerTimer = 0
      elseif wasActive then
        renderViewLingerTimer = renderViewLingerDuration
      end
    end
  end

  if data.rallyClock and data.rallyClock.wallClockSecs ~= nil then
    clockSeconds = data.rallyClock.wallClockSecs
    clockFresh = true
  end

  local countdownData = data.startClockCountdownData or data.countdownData
  if not countdownData then return end

  -- without timeUntilLaunch it is the stage setup warming up the countdown UI, the countdown is not running yet
  local value = countdownData.timeUntilLaunch
  local now = getClockSeconds()
  if value == nil or now == nil then return end

  if value > 0 and countdownData.state ~= 'launched' then
    launchSeconds = (now + value) % 86400
  elseif launchSeconds == nil or getSecondsUntilLaunch(now) > 0 then
    launchSeconds = now
  end
end

function M.onUpdate(dtReal, dtSim)
  if not clocksAreValid() then
    scanTimer = scanTimer - dtReal
    if scanTimer > 0 then return end
    scanTimer = 1
    if not setupClocks() then return end
  end

  if rebindAttempts > 0 then
    rebindTimer = rebindTimer - dtReal
    if rebindTimer <= 0 then
      for _, entry in ipairs(activeTypes) do bindTextures(entry) end
      rebindAttempts = rebindAttempts - 1
      rebindTimer = 0.5
    end
  end
  if renderViewLingerTimer > 0 then
    renderViewLingerTimer = math.max(0, renderViewLingerTimer - dtReal)
  end
  updateRenderView(dtSim)
end

-- drawn after every onUpdate, so the display matches this frame's rally countdown whichever extension updates first
function M.onPreRender(dtReal, dtSim)
  if clockSeconds ~= nil and not clockFresh then
    clockSeconds = (clockSeconds + dtSim) % 86400
  end
  clockFresh = false
  updateDisplay()

  if not renderView or not renderView.active or not renderViewBorderPoints then return end

  debugDrawer:currentRenderViewMaskSet(renderViewMask)
  for index = 1, 4 do
    debugDrawer:drawLineInstance(
      renderViewBorderPoints[index],
      renderViewBorderPoints[index % 4 + 1],
      renderViewBorderWidth,
      renderViewBorderColor,
      false
    )
  end
  debugDrawer:currentRenderViewMaskClear()
end

M.onExtensionLoaded = loadClockTypes
M.onRallySessionEnd = clear
M.onExtensionUnloaded = clear
M.isRenderViewAvailable = function() return renderViewAvailable end
M.getClockTypes = function() return clockTypes end

return M
