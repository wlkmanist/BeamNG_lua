-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

require("utils")
local M = {}
M.dependencies = {"ui_imgui", "core_gamestate", "core_camera"}

local im = ui_imgui
local directionTextures = {}
local activeViews = {}
local active = false
local suppressedForLoadingScreen = false
local directionWindowPos = im.ImVec2(0, 0)
local directionWindowSize = im.ImVec2(0, 0)
local directionWindowPadding = im.ImVec2(0, 0)
local directionWindowPivot = im.ImVec2(0, 0)
local directionCanvasOrigin = Point2I(0, 0)
local directionOverlayFlags = bit.bor(
  im.WindowFlags_NoTitleBar,
  im.WindowFlags_NoResize,
  im.WindowFlags_NoMove,
  im.WindowFlags_NoScrollbar,
  im.WindowFlags_NoScrollWithMouse,
  im.WindowFlags_NoBackground,
  im.WindowFlags_NoInputs,
  im.WindowFlags_NoSavedSettings,
  im.WindowFlags_NoBringToFrontOnFocus,
  im.WindowFlags_NoNavFocus
)
local directionTexturePrefix = "splitScreenPlayerDirections_"
local markerScale = 0.4
local markerBackdropAlpha = 77
local markerAlpha = 255
local hideDistance = 40
local alwaysShowDistance = 100
local hideDistanceSq = hideDistance * hideDistance
local alwaysShowDistanceSq = alwaysShowDistance * alwaysShowDistance
local visibilityDelay = 3
local fadeDuration = 0.5
local safeZonePadding = 0
local camPos = vec3()
local camRot = quat()
local camForward = vec3()
local camRight = vec3()
local camUp = vec3()
local forwardAxis = vec3(0, 1, 0)
local rightAxis = vec3(1, 0, 0)
local upAxis = vec3(0, 0, 1)
local markerStates = {}
local markerBuffer = {}
local playerColors = {}

local function destroy()
  if not active then return end
  if TextureDrawPrimitiveRegistry then
    for viewName in pairs(directionTextures) do
      TextureDrawPrimitiveRegistry:removeName(directionTexturePrefix .. viewName)
    end
  end
  table.clear(directionTextures)
  table.clear(activeViews)
  table.clear(markerStates)
  active = false
end

local function playerColor(colorHexValue, alpha)
  local rgb = playerColors[colorHexValue]
  if not rgb then
    rgb = tonumber(colorHexValue:sub(2), 16)
    playerColors[colorHexValue] = rgb
  end
  return colorHex(rgb, alpha)
end

local function markerWidth(width, minimum, preferred, maximum)
  return math.max(minimum, math.min(maximum, width * preferred))
end

-- a change only takes effect after it stayed stable for visibilityDelay seconds,
local function markerFade(viewName, player, wanted, now)
  local viewStates = markerStates[viewName]
  if not viewStates then
    viewStates = {}
    markerStates[viewName] = viewStates
  end
  local state = viewStates[player]
  if not state then
    state = {shown = wanted, changeTime = now - fadeDuration}
    viewStates[player] = state
  elseif wanted == state.shown then
    state.pendingSince = nil
  elseif not state.pendingSince then
    state.pendingSince = now
  elseif now - state.pendingSince >= visibilityDelay then
    state.shown = wanted
    state.changeTime = now
    state.pendingSince = nil
  end
  local progress = math.min((now - state.changeTime) / fadeDuration, 1)
  return state.shown and progress or 1 - progress
end

local rayDir = vec3()
-- mirrors the --safezone css variable the vue ui uses
local function safeZoneInset(width, height)
  local safeArea = math.min(math.max(settings.getValue("uiLayoutSafeArea", 0.98), 0.8), 1)
  if height > width then width, height = height, width end
  if width / height > 16 / 9 then width = height * 16 / 9 end
  return math.floor(width * (1 - safeArea) / 2 + 0.5)
end

local function occluded(x, y, z)
  rayDir:set(x - camPos.x, y - camPos.y, z - camPos.z)
  local rayLength = rayDir:length()
  if rayLength < 1e-3 then return false end
  rayDir:setScaled(1 / rayLength)
  return castRayStatic(camPos, rayDir, rayLength) < rayLength
end

-- fills markerBuffer with the markers visible in this view and returns how many there are
local function collectMarkers(textureWidth, inset, view, players, vehicleForPlayer, now)
  local markerCount = 0
  local viewerVehicle = vehicleForPlayer(view.player)
  local rect = view.markerRect
  if viewerVehicle and rect then
    camPos:set(core_camera.getPositionXYZ(view.name))
    camRot:set(core_camera.getQuatXYZW(view.name))
    camForward:setRotate(camRot, forwardAxis)
    camRight:setRotate(camRot, rightAxis)
    camUp:setRotate(camRot, upAxis)
    -- the view frustum is symmetric, so clip space is just the camera space offset scaled by fov and aspect
    local tanHalfFov = math.tan(core_camera.getFovRad(view.name) * 0.5)
    local clipScaleY = 1 / tanHalfFov
    local clipScaleX = clipScaleY * math.max(2, rect[4]) / math.max(2, rect[3])
    local viewerVehicleId = viewerVehicle:getID()
    local viewerX, viewerY, viewerZ = viewerVehicle:getPositionXYZ()
    for _, playerInfo in ipairs(players) do
      local vehicle = vehicleForPlayer(playerInfo.player)
      if vehicle and vehicle:getID() ~= viewerVehicleId then
        local x, y, z = vehicle:getPositionXYZ()
        local dx, dy, dz = x - viewerX, y - viewerY, z - viewerZ
        local distanceSq = dx * dx + dy * dy + dz * dz
        local relX, relY, relZ = x - camPos.x, y - camPos.y, z - camPos.z
        local clipW = relX * camForward.x + relY * camForward.y + relZ * camForward.z
        local clipX = (relX * camRight.x + relY * camRight.y + relZ * camRight.z) * clipScaleX
        local clipY = (relX * camUp.x + relY * camUp.y + relZ * camUp.z) * clipScaleY
        -- closer than hideDistance always hides and further than alwaysShowDistance always shows,
        -- so the occlusion ray only matters in between, and only for a player inside the frustum
        local wanted = distanceSq >= hideDistanceSq
        if wanted and distanceSq < alwaysShowDistanceSq
          and clipW > 0 and math.abs(clipX) <= clipW and math.abs(clipY) <= clipW then
          wanted = occluded(x, y, z)
        end
        local fade = markerFade(view.name, playerInfo.player, wanted, now)
        if fade > 0 then
          local screenX = clipX
          local screenY = -clipY - math.min(clipW, 0) - math.abs(clipW) * 2 / 3
          -- directions fan out from below the view center, the marker only ever reaches the top edge
          local topDistance = -screenY * 3 / 5
          if topDistance > 0 and topDistance >= math.abs(screenX) then
            markerCount = markerCount + 1
            local marker = markerBuffer[markerCount]
            if not marker then
              marker = {}
              markerBuffer[markerCount] = marker
            end
            marker.centerX = inset + (screenX / topDistance + 1) * 0.5 * math.max(textureWidth - inset * 2, 0)
            marker.color = playerColor(playerInfo.color, markerAlpha * fade)
            marker.backdropColor = color(0, 0, 0, markerBackdropAlpha * fade)
          end
        end
      end
    end
  end
  return markerCount
end

local function update(enabled, views, players, vehicleForPlayer)
  if core_gamestate.loading() then
    suppressedForLoadingScreen = true
  end
  local multiseatFreeroamActive = ui_multiseat_freeroam and ui_multiseat_freeroam.isActive()
  if suppressedForLoadingScreen or not multiseatFreeroamActive or not enabled or not TextureDrawPrimitiveRegistry
    or not players or #players < 2 then
    if active then destroy() end
    return
  end
  active = true

  local canvas = scenetree.findObject("Canvas")
  if not canvas or not canvas.getWindowClientSizeXY then return end
  local canvasWidth, canvasHeight = canvas:getWindowClientSizeXY()
  if not canvasWidth or not canvasHeight or canvasWidth < 2 or canvasHeight < 2 then return end
  safeZonePadding = safeZoneInset(canvasWidth, canvasHeight)

  local viewportsEnabled = bit.band(im.getIOConfigFlags(), im.ConfigFlags_ViewportsEnable) ~= 0
  local canvasX, canvasY = 0, 0
  if viewportsEnabled then
    if not canvas.clientToScreenXY then return end
    canvasX, canvasY = canvas:clientToScreenXY(directionCanvasOrigin)
    if not canvasX or not canvasY then return end
  end

  -- these overlays are transparent and cover a whole pane, so imgui would give one its own
  -- platform window, where NoBackground has nothing to show through and presents as opaque black
  local mainViewportId = im.getMainViewPortId()

  table.clear(activeViews)
  local now = os.clockhp()
  for _, view in ipairs(views) do
    local rect = view.markerRect
    local textureWidth, textureHeight = rect and rect[3] or 0, rect and rect[4] or 0
    if textureWidth > 0 and textureHeight > 0 then
      activeViews[view.name] = true
      local fillRadius = markerWidth(textureWidth, 0.666 * 16, 0.04, 1.2 * 16) * markerScale
      local outlineWidth = markerWidth(textureWidth, 16, 0.06, 1.8 * 16) * markerScale - fillRadius
      -- keep the whole circle, outline included, inside the safe zone
      local inset = safeZonePadding + fillRadius + outlineWidth
      local markerCount = collectMarkers(textureWidth, inset, view, players, vehicleForPlayer, now)
      -- a view without markers needs no window and no texture upload at all
      if markerCount > 0 then
        local entry = directionTextures[view.name]
        if not entry or textureWidth ~= entry.width or textureHeight ~= entry.height then
          local texture = TextureDrawPrimitiveRegistry:getOrCreate(directionTexturePrefix .. view.name, textureWidth, textureHeight)
          texture:setWidthHeight(textureWidth, textureHeight)
          texture:setClearColor(0)
          texture:setClearFlag("WhenDirty")
          entry = {texture = texture, width = textureWidth, height = textureHeight}
          directionTextures[view.name] = entry
        end
        local texture = entry.texture
        texture:circle(-1, -1, 1, 0, 0, 0, 0, 0)
        for i = 1, markerCount do
          local marker = markerBuffer[i]
          texture:circle(marker.centerX, inset, fillRadius, outlineWidth, marker.color, marker.color, marker.backdropColor, marker.backdropColor)
        end
        directionWindowPos.x, directionWindowPos.y = canvasX + rect[1], canvasY + rect[2]
        directionWindowSize.x, directionWindowSize.y = textureWidth, textureHeight
        im.SetNextWindowPos(directionWindowPos, im.Cond_Always, directionWindowPivot)
        im.SetNextWindowSize(directionWindowSize, im.Cond_Always)
        im.SetNextWindowViewport(mainViewportId)
        im.PushStyleVar2(im.StyleVar_WindowPadding, directionWindowPadding)
        if im.Begin("Split Screen Player Directions##" .. view.name, nil, directionOverlayFlags) then
          texture:ImGui_Image(textureWidth, textureHeight)
        end
        im.End()
        im.PopStyleVar(1)
      end
    end
  end
  for viewName in pairs(directionTextures) do
    if not activeViews[viewName] then
      TextureDrawPrimitiveRegistry:removeName(directionTexturePrefix .. viewName)
      directionTextures[viewName] = nil
    end
  end
end

local function onLoadingScreenInactive(state)
  if state == 2 then
    suppressedForLoadingScreen = false
  end
end

M.update = update
M.destroy = destroy
M.onLoadingScreenInactive = onLoadingScreenInactive

return M
