-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local layers = require("ui/apps/minimap/layers")

-- Color definitions
local clrFocus = color(255,115,10,255)
local clrFocusMuted = color(255*0.8,165*0.8,80,255)
local clrGrayMuted = color(100,100,100,255)
local clrRoadBgTransparentBlack = color(50, 50, 50, 255)
local clrNavBgBlack = color(70,70,70,255)
local clrGridWhite = color(160,160,160,255)
local clrNavBg = color(255,255,255,255)
local clrNavFg = color(0,0.4*255,1*255,255)

-- State variables that need to be set by the main minimap
local width, height
local centerX, centerY
local camPos, camRot, camRotInverse
local scale, scaleInverse
local td
local offsetX, offsetY
local mode
M.dpi = 1

local camFwd, camRight = vec3(), vec3()
local camInverseFwd, camInverseRight = vec3(), vec3()
local halfWidthWithOffset = 0
local halfHeightWithOffset = 0
local worldToMapXX, worldToMapXYCoef, worldToMapXOffset = 0, 0, 0
local worldToMapYX, worldToMapYY, worldToMapYOffset = 0, 0, 0

-- Setter function to update state from main minimap
M.setMinimapState = function(w, h, cx, cy, cp, cr, cri, s, si, textureDraw, ox, oy, minimapMode, dpi)
  width = w
  height = h
  centerX = cx
  centerY = cy
  camPos = cp
  camRot = cr
  camRotInverse = cri
  scale = s
  scaleInverse = si
  td = textureDraw
  offsetX = ox or 0
  offsetY = oy or 0
  mode = minimapMode or "circle"
  M.dpi = dpi or 1
  camFwd:set(1,0,0)
  camFwd:setRotate(camRot)
  camRight:set(0,1,0)
  camRight:setRotate(camRot)
  halfWidthWithOffset = width*0.5 + offsetX
  halfHeightWithOffset = height*0.5 + offsetY

  worldToMapXX = scaleInverse * camFwd.x
  worldToMapXYCoef = scaleInverse * camRight.x
  worldToMapYX = -scaleInverse * camFwd.y
  worldToMapYY = -scaleInverse * camRight.y
  worldToMapXOffset = halfWidthWithOffset - camPos.x * worldToMapXX - camPos.y * worldToMapXYCoef
  worldToMapYOffset = halfHeightWithOffset - camPos.x * worldToMapYX - camPos.y * worldToMapYY

  camInverseFwd:set(1,0,0)
  camInverseFwd:setRotate(camRotInverse)
  camInverseRight:set(0,1,0)
  camInverseRight:setRotate(camRotInverse)
end

-- Transform functions
local function worldToMap(p)
  local cp = p-camPos
  -- offset
  cp = cp / scale
  --rotate
  cp = camRot*cp

  cp:set(cp.x + width/2, height - cp.y -  height/2,0)
  return cp
end


--  local x = (source.x - camPos.x) * scaleInverse * camFwd.x + (source.y - camPos.y) * scaleInverse * camRight.x
--local y = (source.x - camPos.x) * scaleInverse * camFwd.y + (source.y - camPos.y) * scaleInverse * camRight.y
local function worldToMapXYZ(target, source)
  local x, y = source.x, source.y
  target:set(
    x * worldToMapXX + y * worldToMapXYCoef + worldToMapXOffset,
    x * worldToMapYX + y * worldToMapYY + worldToMapYOffset,
    0
  )
end

local function worldToMapXY(x,y )
  return x * worldToMapXX + y * worldToMapXYCoef + worldToMapXOffset,
         x * worldToMapYX + y * worldToMapYY + worldToMapYOffset
end

local function worldLineToMapXY(x1, y1, x2, y2)
  return x1 * worldToMapXX + y1 * worldToMapXYCoef + worldToMapXOffset,
         x1 * worldToMapYX + y1 * worldToMapYY + worldToMapYOffset,
         x2 * worldToMapXX + y2 * worldToMapXYCoef + worldToMapXOffset,
         x2 * worldToMapYX + y2 * worldToMapYY + worldToMapYOffset
end

local function getWorldToMapTransform()
  return worldToMapXX, worldToMapXYCoef, worldToMapYX, worldToMapYY, worldToMapXOffset, worldToMapYOffset
end



local function worldToMapXYInverse(x,y )
  -- Convert from map coordinates to world coordinates
  local mapX = x - halfWidthWithOffset
  local mapY = halfHeightWithOffset - y

  -- Solve the system of equations:
  -- mapX = tX * camFwd.x + y * camRight.x
  -- mapY = tX * camFwd.y + y * camRight.y

  -- Using Cramer's rule to solve for tX and y
  local det = camFwd.x * camRight.y - camFwd.y * camRight.x
  local tX = (mapX * camRight.y - mapY * camRight.x) / det
  local worldY = (camFwd.x * mapY - camFwd.y * mapX) / det

  -- Convert back to world coordinates
  local worldX = tX / scaleInverse + camPos.x
  worldY = worldY / scaleInverse + camPos.y

  return worldX, worldY
end

local function mapToWorld(p)
  local cp = vec3(p.x-centerX, -(p.y - centerY),0)
  cp = camRotInverse * cp
  cp = cp * scale
  cp = cp + camPos
  return cp
end

-- Utility functions
M.isInsideMinimapBounds = function(pos, buffer)
  buffer = buffer or 0
  return pos.x > (offsetX + buffer)
    and pos.x < (offsetX + width - buffer)
    and pos.y > (offsetY + buffer)
    and pos.y < (offsetY + height - buffer)
end

local clampToMinimapBounds = function(pos, buffer)
  buffer = buffer or 0
  pos.x = clamp(pos.x, offsetX - buffer, offsetX + width + buffer)
  pos.y = clamp(pos.y, offsetY - buffer, offsetY + height + buffer)
end

-- Returns the clamped position and a flag indicating whether clamping happened
local function setClampToBounds(pos, inset, maxDistance)
  inset = inset or 0
  local centerX = width * 0.5 + offsetX
  local centerY = height * 0.5 + offsetY
  local targetX, targetY = pos.x, pos.y
  local deltaX, deltaY = targetX - centerX, targetY - centerY
  local distanceSquared = deltaX * deltaX + deltaY * deltaY

  if distanceSquared <= 1e-12 then
    pos:set(centerX, centerY, 0)
    return pos, false
  end

  if mode == "circle" then
    local radius = width * 0.5 - inset
    if distanceSquared > radius * radius then
      local scaleToBounds = radius / math.sqrt(distanceSquared)
      pos:set(centerX + deltaX * scaleToBounds, centerY + deltaY * scaleToBounds, 0)
      return pos, true
    end
    pos:set(targetX, targetY, 0)
    return pos, false
  end

  local halfWidth = (width - 2 * inset) * 0.5
  local halfHeight = (height - 2 * inset) * 0.5
  local absDeltaX, absDeltaY = math.abs(deltaX), math.abs(deltaY)

  if absDeltaX <= halfWidth and absDeltaY <= halfHeight then
    pos:set(targetX, targetY, 0)
    return pos, false
  end

  local scaleX = absDeltaX > 1e-6 and halfWidth / absDeltaX or math.huge
  local scaleY = absDeltaY > 1e-6 and halfHeight / absDeltaY or math.huge
  local scaleToBounds = math.min(scaleX, scaleY)
  pos:set(centerX + deltaX * scaleToBounds, centerY + deltaY * scaleToBounds, 0)
  return pos, true
end

-- Drawing utility functions
local strikeWidth = 3.0
local fillColor = color(254,102,1,255)
local strikeColor = color(255,255,255,255)
local simpleCircle = function(pos, fill, strikeClr, radius)
  td:circleMarker(pos.x, pos.y, radius or 6, strikeWidth, M.dpi, fill or fillColor, strikeClr or strikeColor, worldToMapXX, worldToMapXYCoef, worldToMapYX, worldToMapYY, worldToMapXOffset, worldToMapYOffset, layers.GAMEPLAY_MARKERS)
end

local simpleLine = function(pos1, pos2, fill, strikeClr)
  td:lineRoundEndTransformed(pos1.x, pos1.y, pos2.x, pos2.y, strikeWidth*M.dpi, strikeWidth*M.dpi, fill or fillColor, strikeClr or strikeColor, worldToMapXX, worldToMapXYCoef, worldToMapYX, worldToMapYY, worldToMapXOffset, worldToMapYOffset, layers.GAMEPLAY_MARKERS)
end

-- Edge pointer function: returns false if the position is inside of the minimap (nothing drawn)
-- the border color is always clrNavBg and the stroke is always white, strikeClr is unused
local drawEdgePointer = function(pos, fill, strikeClr, radius, maxDistance)
  return td:edgePointer(pos.x, pos.y, width, height, offsetX, offsetY, mode == "circle", radius or 6, maxDistance or math.huge, M.dpi, fill or fillColor, clrNavBg, strikeColor, worldToMapXX, worldToMapXYCoef, worldToMapYX, worldToMapYY, worldToMapXOffset, worldToMapYOffset, layers.ROUTE_POINTER)
end

local simpleCircleWithEdgePointer = function(pos, fill, strikeClr, radius)
  if not drawEdgePointer(pos, fill, strikeClr, radius or 6) then
    simpleCircle(pos, fill, strikeClr, radius or 6)
  end
end

local center = vec3()
local simpleLineWithEdgePointer = function(pos1, pos2, fill, strikeClr)
  center:set(pos1)
  center:setAdd(pos2)
  center:setScaled(0.5)
  if not drawEdgePointer(center, fill, strikeClr) then
    simpleLine(pos1, pos2, fill, strikeClr)
  end
end



-- Expose functions
M.worldToMap = worldToMap
M.worldToMapXYZ = worldToMapXYZ
M.worldToMapXY = worldToMapXY
M.worldLineToMapXY = worldLineToMapXY
M.getWorldToMapTransform = getWorldToMapTransform
M.mapToWorld = mapToWorld
M.simpleCircle = simpleCircle
M.simpleLine = simpleLine
M.simpleCircleWithEdgePointer = simpleCircleWithEdgePointer
M.simpleLineWithEdgePointer = simpleLineWithEdgePointer
M.drawEdgePointer = drawEdgePointer
M.clampToMinimapBounds = clampToMinimapBounds
M.setClampToBounds = setClampToBounds
M.centerPointer = centerPointer
-- Grid drawing function
M.drawGrid = function()
  -- Grid spacing in world units (50 meters)
  local gridSpacing = 50

  -- Calculate the visible area in world coordinates
  local radius = math.max(width, height) * scale * 0.5
  local minX = camPos.x - radius
  local maxX = camPos.x + radius
  local minY = camPos.y - radius
  local maxY = camPos.y + radius

  -- Calculate grid line positions
  local startX = math.floor(minX / gridSpacing) * gridSpacing
  local endX = math.ceil(maxX / gridSpacing) * gridSpacing
  local startY = math.floor(minY / gridSpacing) * gridSpacing
  local endY = math.ceil(maxY / gridSpacing) * gridSpacing

  -- Draw vertical lines (X-axis aligned)
  for x = startX, endX, gridSpacing do
    local x1, y1 = worldToMapXY(x, minY - radius)
    local x2, y2 = worldToMapXY(x, maxY + radius)
    td:line(x1, y1, x2, y2, 0, 0, 0.5, 0.5, clrGridWhite, clrGridWhite, clrGridWhite, clrGridWhite, 0, layers.BG_GRID)
  end

  -- Draw horizontal lines (Y-axis aligned)
  for y = startY, endY, gridSpacing do
    local x1, y1 = worldToMapXY(minX - radius, y)
    local x2, y2 = worldToMapXY(maxX + radius, y)
    td:line(x1, y1, x2, y2, 0, 0, 0.5, 0.5, clrGridWhite, clrGridWhite, clrGridWhite, clrGridWhite, 0, layers.BG_GRID)
  end
end

-- Style color set data
local StyleColorSet = {
  {
    name = "Default",
    color = color(220,220,220,255),
    colorLow = color(150,150,120,255),
    colorLowest = color(150,120,100,255),
    clrFocus = clrFocus,
    clrFocusMuted = clrFocusMuted,
    gridWhite = clrGridWhite,
    navFg = clrNavFg,
    navBg = clrNavBg,
    grayMuted = clrGrayMuted,
  },
  {
    name = "Monochrome",
    color = color(200,200,200,255),
    colorLow = color(170,170,170,255),
    colorLowest = color(140,140,140,255),
    clrFocus = color(240,240,240,255),
    clrFocusMuted = color(200,200,200,255),
    gridWhite = clrGridWhite,
    navFg = color(255,255,255,255),
    navBg = color(32,32,64,255),
    grayMuted = clrGrayMuted,
  },
  {
    name = "Green",
    color = color(220,220,220,255),
    colorLow = color(120,200,120,255),
    colorLowest = color(90,150,60,255),
    clrFocus = clrFocus,
    clrFocusMuted = clrFocusMuted,
    gridWhite = clrGridWhite,
    navFg = clrNavFg,
    navBg = clrNavBg,
    grayMuted = clrGrayMuted,
  },
  {
    name = "Blue",
    color = color(220,220,220,255),
    colorLow = color(120,120,200,255),
    colorLowest = color(90,60,150,255),
    clrFocus = clrFocus,
    clrFocusMuted = clrFocusMuted,
    gridWhite = clrGridWhite,
    navFg = clrNavFg,
    navBg = clrNavBg,
    grayMuted = clrGrayMuted,
  },
  {
    name = "Orange",
    color = color(220,220,220,255),
    colorLow = color(200,180,160,255),
    colorLowest = color(180,150,100,255),
    clrFocus = clrFocus,
    clrFocusMuted = clrFocusMuted,
    gridWhite = clrGridWhite,
    navFg = clrNavFg,
    navBg = clrNavBg,
    grayMuted = clrGrayMuted,
  },
  {
    name = "Grayscale",
    color = color(220,220,220,255),
    colorLow = color(150,150,150,255),
    colorLowest = color(100,100,100,255),
    clrFocus = clrFocus,
    clrFocusMuted = clrFocusMuted,
    gridWhite = clrGridWhite,
    navFg = clrNavFg,
    navBg = clrNavBg,
    grayMuted = clrGrayMuted,
  },
}

-- Default style road color set index
local defaultStyleRoadColorSet = 1

-- Expose colors
M.colors = {
  orange = clrFocus,
  orangeMuted = clrFocusMuted,
  grayMuted = clrGrayMuted,
  roadBgTransparentBlack = clrRoadBgTransparentBlack,
  navBgBlack = clrNavBgBlack,
  gridWhite = clrGridWhite,
  navBgWhite = clrNavBg,
  navFgBlue = clrNavFg
}

-- Getter for StyleColorSet
M.getStyleColorSet = function()
  return StyleColorSet
end

-- Getter for default style color set index
M.getDefaultStyleColorSet = function()
  return defaultStyleRoadColorSet
end

-- Getter for current style colors
M.getCurrentStyleColors = function()
  local StyleColorSet = M.getStyleColorSet()
  local defaultStyleColorSet = M.getDefaultStyleColorSet()
  return StyleColorSet[defaultStyleColorSet]
end

return M