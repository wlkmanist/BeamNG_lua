-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
local arrowPrefix = "arrow_marker_"
local flagPrefix = "flag_marker_"
local columnPrefix = "column_marker_"
local arrowShape = "/art/shapes/interface/s_mm_arrow_ribbon_down.dae"
local flagShape = "/art/shapes/race/flagMarkerOrange.dae"
local columnShape = "art/shapes/interface/s_single_faded_column_rect.dae"

local modeInfos = {
  default = {
    color = {1, 1, 1},
    baseColor = {1, 1, 1},
    showBase = true,
  },
  inactive = {
    color = {0.5, 0.5, 0.5},
    baseColor = {0.5, 0.5, 0.5},
    showBase = true,
  },
  current = {
    color = {1, 0.5, 0},
    baseColor = {1, 1, 1},
    showBase = true,
  },
  recovery = {
    color = {1, 0.85, 0},
    baseColor = {1, 1, 1},
    showBase = true,
  },
  bonus = {
    color = {0.8, 0.2, 1},
    baseColor = {1, 1, 1},
    showBase = true,
  },
  skipped = {
    color = {1, 0.07, 0},
    baseColor = {1, 1, 1},
    showBase = true,
  },
  final = {
    color = {0.1, 0.3, 1},
    baseColor = {1, 1, 1},
    showBase = true,
  },
  finished = {
    color = {0.4, 1, 0.2},
    baseColor = {1, 1, 1},
    showBase = false,
  },
  hidden = {
    color = {0, 0, 0},
    baseColor = {0, 0, 0},
    showBase = false,
  }
}

local fadeNear = 5
local fadeFar = 25
local arrowHeight = 3
local arrowStartHeight = -2
local FLAG_OFFSET = 2.5
local ARROW_HEIGHT_MOVE_SQ = 25
local ARROW_YAW_DOT = 0.9986
local activeModes = {current = true, recovery = true, bonus = true, final = true}

local tmpPlayerPos = vec3()
local tmpArrowPos = vec3()
local tmpRayDir = vec3()
local tmpFlagPos = vec3()
local tmpRightDir = vec3()
local tmpTerrainUp = vec3()
local lerpedColor = {1, 1, 1}

local function inverseLerp(min, max, value)
 if math.abs(max - min) < 1e-30 then return min end
 return (value - min) / (max - min)
end

-- todo: replace this by a HSV-lerp if blending with non-gray colors
local function lerpColor(a,b,t)
  lerpedColor[1] = lerp(a[1],b[1],t)
  lerpedColor[2] = lerp(a[2],b[2],t)
  lerpedColor[3] = lerp(a[3],b[3],t)
  return lerpedColor
end

function C:init(id)
  self.id = id
  self.visible = false
  self.renderViewPlayer = nil

  self.pos = nil
  self.radius = nil
  self.color = nil
  self.pathDirection = vec3(0, 1, 0)

  self.fadeNear = fadeNear
  self.fadeFar = fadeFar

  self.colorTimer = 0
  self.colorLerpDuration = 0.5

  self.arrow = nil
  self.flagLeft = nil
  self.flagRight = nil
  self.column = nil
  self.columnId = nil
  self.flagColor = ColorF(1,1,1,1):asLinear4F()
  self.arrowColor = ColorF(1,1,1,1):asLinear4F()
  self.arrowColorWhite = ColorF(1,1,1,1):asLinear4F()
  self.arrowColorClear = ColorF(0,0,0,0):asLinear4F()
  self.currentColor = ColorF(1,1,1,1)

  self.mode = 'hidden'
  self.oldMode = 'hidden'
  self.modeInfos = deepcopy(modeInfos)

  self.arrowHeightSmoother = newTemporalSpring()
  self.baseArrowScale = 2.0
  self.arrowScaleSmoother = newTemporalSpring(30, 10, self.baseArrowScale)
  self.columnColor = ColorF(1,1,1,1):asLinear4F()
  self.columnAlphaSmoother = newTemporalSpring()
  self.columnAlphaSmoother:set(0.0)
  self.arrowRot = quat()
  self.arrowFacing = vec3()
end

local function snapFlagToGround(pos)
  tmpTerrainUp:set(0, 0, 1)
  if core_terrain then
    local terrainHeight = core_terrain.getTerrainHeight(pos)
    if terrainHeight then
      pos.z = terrainHeight
    end
    local terrainNormal = core_terrain.getTerrainSmoothNormal(pos)
    if terrainNormal then
      tmpTerrainUp:set(terrainNormal)
    end
  else
    tmpArrowPos:set(pos.x, pos.y, pos.z + 1)
    local surfaceHeight = be:getSurfaceHeightBelow(tmpArrowPos)
    if surfaceHeight then
      pos.z = surfaceHeight + 0.1
    end
    local surfaceNormal = map.surfaceNormal(pos, 1)
    if surfaceNormal then
      tmpTerrainUp:set(surfaceNormal)
    end
  end
end

local function placeFlag(obj, pos, forwardDir)
  if not obj then return end
  obj:setPosition(vec3(pos))
  local flagRot = quatFromDir(forwardDir, tmpTerrainUp)
  obj:setField('rotation', 0, flagRot.x .. ' ' .. flagRot.y .. ' ' .. flagRot.z .. ' ' .. flagRot.w)
end

function C:placeFlags()
  if not self.pos then return end
  local forwardDir = self.pathDirection
  tmpRightDir:set(forwardDir.y, -forwardDir.x, 0)
  if tmpRightDir:squaredLength() > 1e-8 then
    tmpRightDir:normalize()
  else
    tmpRightDir:set(1, 0, 0)
  end

  if self.flagLeft then
    tmpFlagPos:set(self.pos.x + tmpRightDir.x * FLAG_OFFSET, self.pos.y + tmpRightDir.y * FLAG_OFFSET, self.pos.z)
    snapFlagToGround(tmpFlagPos)
    placeFlag(self.flagLeft, tmpFlagPos, forwardDir)
  end
  if self.flagRight then
    tmpFlagPos:set(self.pos.x - tmpRightDir.x * FLAG_OFFSET, self.pos.y - tmpRightDir.y * FLAG_OFFSET, self.pos.z)
    snapFlagToGround(tmpFlagPos)
    placeFlag(self.flagRight, tmpFlagPos, forwardDir)
  end
end

function C:update(dt, dtSim)
  self.colorTimer = self.colorTimer + dt
  if self.colorTimer >= self.colorLerpDuration then
    if self.mode == 'hidden' then
      self:hide()
    end
  end
  if not self.visible then return end

  local cameraContext = self.renderViewPlayer ~= nil
    and core_camera.getContextIdForPlayer(self.renderViewPlayer)
    or nil
  tmpPlayerPos:set(core_camera.getPositionXYZ(cameraContext))

  local dx = self.pos.x - tmpPlayerPos.x
  local dy = self.pos.y - tmpPlayerPos.y
  local distanceFromMarker = math.sqrt(dx * dx + dy * dy)

  local t = clamp(self.colorTimer / self.colorLerpDuration,0,1)
  local color = lerpColor(self.modeInfos[self.oldMode or 'default'].color, self.modeInfos[self.mode or 'default'].color, t)

  self.currentColor.r = color[1]
  self.currentColor.g = color[2]
  self.currentColor.b = color[3]
  self.currentColor.a = (color[4] or 1) * (clamp(inverseLerp(self.fadeNear,self.fadeFar,distanceFromMarker),0,1))

  if self.flagLeft or self.flagRight then
    local a = self.currentColor.a
    if self.lastFlagAlpha ~= a then
      self.lastFlagAlpha = a
      self.flagColor.w = a
      if self.flagLeft then
        self.flagLeft.instanceColor = self.flagColor
        self.flagLeft:updateInstanceRenderData()
      end
      if self.flagRight then
        self.flagRight.instanceColor = self.flagColor
        self.flagRight:updateInstanceRenderData()
      end
    end
  end

  if self.arrow then
    tmpRayDir:set(tmpPlayerPos.x - self.pos.x, tmpPlayerPos.y - self.pos.y, 0)
    if tmpRayDir:squaredLength() > 1e-8 then
      tmpRayDir:normalize()
      if self.arrowFacing:squaredLength() < 1e-8 or self.arrowFacing:dot(tmpRayDir) < ARROW_YAW_DOT then
        self.arrowFacing:set(tmpRayDir)
        self.arrowRot:setFromDir(tmpRayDir)
      end
    end

    if self.mode == 'hidden' then
      self.arrow.instanceColor = self.arrowColorClear
      self.arrow.instanceColor1 = self.arrowColorClear
    else
      self.arrowColor.x = self.currentColor.r
      self.arrowColor.y = self.currentColor.g
      self.arrowColor.z = self.currentColor.b
      self.arrowColor.w = self.currentColor.a
      self.arrowColorWhite.w = self.currentColor.a
      self.arrow.instanceColor = self.arrowColor
      self.arrow.instanceColor1 = self.arrowColorWhite
    end

    local currentTime = os.clock()
    self.delay = self.delay - dtSim
    local baseTargetHeight = self.delay < 0 and arrowHeight or arrowStartHeight

    local targetHeight = baseTargetHeight
    if activeModes[self.mode] then
      local camMoved = not self.arrowHeightCamPos or tmpPlayerPos:squaredDistance(self.arrowHeightCamPos) > ARROW_HEIGHT_MOVE_SQ
      if camMoved then
        local testHeight = baseTargetHeight
        local maxTestHeight = 100
        local heightIncrement = 4
        targetHeight = baseTargetHeight

        while testHeight <= maxTestHeight do
          tmpArrowPos:set(self.pos.x, self.pos.y, self.pos.z + testHeight)
          tmpRayDir:set(tmpPlayerPos)
          tmpRayDir:setSub(tmpArrowPos)
          local rayLength = tmpRayDir:length()
          if castRayStatic(tmpArrowPos, tmpRayDir, rayLength, nil) >= rayLength then
            targetHeight = testHeight
            break
          end
          testHeight = testHeight + heightIncrement
        end

        if not self.arrowHeightCamPos then
          self.arrowHeightCamPos = vec3()
        end
        self.arrowHeightCamPos:set(tmpPlayerPos)
        self.cachedArrowTargetHeight = targetHeight
      else
        targetHeight = self.cachedArrowTargetHeight or baseTargetHeight
      end
    end

    local sinOffset = self.delay < 0 and math.sin(currentTime * 1.9 + self.originalDelay) * 0.4 or 0
    targetHeight = targetHeight + sinOffset

    local currentArrowHeight = self.arrowHeightSmoother:get(targetHeight, dtSim)
    tmpArrowPos:set(self.pos.x, self.pos.y, self.pos.z + currentArrowHeight)
    local q = self.arrowRot
    self.arrow:setPosRot(tmpArrowPos.x, tmpArrowPos.y, tmpArrowPos.z, q.x, q.y, q.z, q.w)

    local targetScale = distanceFromMarker < 15.0 and 0.3 or self.baseArrowScale
    if self.mode == 'finished' or self.mode == 'inactive' then
      targetScale = targetScale * 0.4
    end
    local currentScale = self.arrowScaleSmoother:get(targetScale, dtSim)
    tmpRightDir:set(currentScale, currentScale, currentScale)
    self.arrow:setScale(tmpRightDir)
    self.arrow:updateInstanceRenderData()
  end

  if self.column then
    local targetAlpha = 0.0
    local columnHeight = 200.0
    local fadeStart, fadeEnd = 200.0, 300.0
    local heightStart = 200.0
    if activeModes[self.mode] then
      fadeStart, fadeEnd = 40.0, 80.0
      heightStart = 40.0
    end

    if distanceFromMarker >= fadeStart then
      if distanceFromMarker >= fadeEnd then
        targetAlpha = 1.0
      else
        targetAlpha = clamp(inverseLerp(fadeStart, fadeEnd, distanceFromMarker), 0, 1)
      end

      if distanceFromMarker >= 1200.0 then
        columnHeight = 200.0
      else
        columnHeight = lerp(50.0, 200.0, clamp(inverseLerp(heightStart, 1200.0, distanceFromMarker), 0, 1))
      end
    end

    local currentAlpha = self.columnAlphaSmoother:get(targetAlpha, dtSim)

    if currentAlpha > 0.01 and self.mode ~= 'hidden' then
      self.column.hidden = false
      self.columnColor.x = color[1]
      self.columnColor.y = color[2]
      self.columnColor.z = color[3]
      self.columnColor.w = currentAlpha * 0.95
      self.column.instanceColor = self.columnColor
      local columnRadius = self.radius or 2.0
      tmpRightDir:set(columnRadius, columnRadius, columnHeight)
      self.column:setScale(tmpRightDir)
      self.column:updateInstanceRenderData()
    else
      self.column.hidden = true
    end
  end
end

function C:setToCheckpoint(wp)
  self.pos = vec3(wp.pos)

  if core_terrain then
    local terrainHeight = core_terrain.getTerrainHeight(self.pos)
    if terrainHeight then
      self.pos.z = terrainHeight
    end
  else
    local surfaceHeight = be:getSurfaceHeightBelow(self.pos + vec3(0, 0, 1))
    if surfaceHeight then
      self.pos.z = surfaceHeight + 0.1
    end
  end

  self.radius = wp.radius

  self.fadeNear = wp.fadeNear or self.fadeNear
  self.fadeFar = wp.fadeFar or self.fadeFar
  self.delay = wp.delay or 0
  self.originalDelay = self.delay

  local forwardDir = vec3(0, 1, 0)
  if wp.dir then
    forwardDir = vec3(wp.dir):normalized()
  elseif wp.nextPos then
    forwardDir = (vec3(wp.nextPos) - self.pos):normalized()
  end
  self.pathDirection = forwardDir

  if self.arrow then
    self.arrowHeightSmoother:set(arrowStartHeight)
    tmpArrowPos:set(self.pos.x, self.pos.y, self.pos.z + arrowStartHeight)
    self.arrow:setPosition(tmpArrowPos)
  end

  if self.column then
    self.column:setPosition(self.pos)
    local columnRadius = self.radius or 2.0
    tmpRightDir:set(columnRadius, columnRadius, 200)
    self.column:setScale(tmpRightDir)
  end

  self.arrowHeightCamPos = nil
  self.cachedArrowTargetHeight = nil
  self.arrowFacing:set(0, 0, 0)
  self:placeFlags()
end
function C:drawOnMinimap(td)
  if self.mode == 'hidden' then
    return
  end
  ui_apps_minimap_utils.simpleCircle(self.pos, color(self.currentColor.r*255, self.currentColor.g*255, self.currentColor.b*255, 255))
end

function C:setMode(mode)
  if mode ~= 'hidden' then
    self:show()
  else
    self:hide()
  end
  if mode == self.mode then
    return
  end
  self.oldMode = self.mode
  self.mode = mode
  self.colorTimer = 0
  self.arrowHeightCamPos = nil
  self.cachedArrowTargetHeight = nil

  self:update(0,0)
end

function C:setVisibility(v)
  self.visible = v

  if self.arrow then
    self.arrow.hidden = not v
  end
  if self.flagLeft then
    self.flagLeft.hidden = not v
  end
  if self.flagRight then
    self.flagRight.hidden = not v
  end
  if self.column then
    self.column.hidden = not v
  end
end

function C:hide() self:setVisibility(false) end
function C:show() self:setVisibility(true)  end

local function applyRenderViewMask(object, viewPlayer)
  if not object then return end
  object:renderViewMaskClear()
  if viewPlayer == nil then return end

  local players = render_splitScreen and render_splitScreen.getPlayers
    and render_splitScreen.getPlayers()
    or {}
  for _, player in ipairs(players) do
    if player ~= viewPlayer then
      object:hideInRenderView(player)
    end
  end
end

function C:applyRenderViewMask()
  applyRenderViewMask(self.arrow, self.renderViewPlayer)
  applyRenderViewMask(self.flagLeft, self.renderViewPlayer)
  applyRenderViewMask(self.flagRight, self.renderViewPlayer)
  applyRenderViewMask(self.column, self.renderViewPlayer)
end

function C:setRenderViewPlayer(player)
  self.renderViewPlayer = player
  self:applyRenderViewMask()
end

function C:createObject(shapeName, objectName)
  local marker =  createObject('TSStatic')
  marker.dynamic = true
  marker:setField('shapeName', 0, shapeName)
  marker:setPosition(vec3(0, 0, 0))
  marker.scale = vec3(1, 1, 1)
  marker:setField('rotation', 0, '1 0 0 0')
  marker.useInstanceRenderData = true
  marker:setField('instanceColor', 0, '1 1 1 1')
  marker:setInternalName('marker')
  marker.canSave = false
  marker.hidden = true
  marker:registerObject(objectName)

  local scenarioObjectsGroup = scenetree.ScenarioObjectsGroup
  if scenarioObjectsGroup then
    scenarioObjectsGroup:addObject(marker)
  end

  return marker
end

function C:createMarkers()
  self:clearMarkers()
  self._ids = {}
  if not self.arrow then
    self.arrow = self:createObject(arrowShape,arrowPrefix..self.id)
    local initialScale = self.baseArrowScale or 2.0
    self.arrow:setScale(vec3(initialScale, initialScale, initialScale))
    if self.arrowScaleSmoother then
      self.arrowScaleSmoother:set(initialScale)
    end
    table.insert(self._ids, self.arrow:getId())
  end
  if not self.flagLeft then
    self.flagLeft = self:createObject(flagShape,flagPrefix.."left_"..self.id)
    table.insert(self._ids, self.flagLeft:getId())
  end
  if not self.flagRight then
    self.flagRight = self:createObject(flagShape,flagPrefix.."right_"..self.id)
    table.insert(self._ids, self.flagRight:getId())
  end
  if not self.column then
    local columnObj = self:createObject(columnShape, columnPrefix..self.id)
    self.column = columnObj
    self.columnId = columnObj:getId()
    table.insert(self._ids, self.columnId)
    columnObj.hidden = true
  end
  self:applyRenderViewMask()
end

function C:clearMarkers()
  for _, id in ipairs(self._ids or {}) do
    local obj = scenetree.findObjectById(id)
    if obj then
      obj:renderViewMaskClear()
      obj:delete()
    end
  end
  self._ids = nil
  self.arrow = nil
  self.flagLeft = nil
  self.flagRight = nil
  self.column = nil
  self.columnId = nil
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
