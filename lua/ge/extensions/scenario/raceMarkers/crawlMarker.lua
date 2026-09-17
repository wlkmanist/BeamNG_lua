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

local function inverseLerp(min, max, value)
 if math.abs(max - min) < 1e-30 then return min end
 return (value - min) / (max - min)
end

-- todo: replace this by a HSV-lerp if blending with non-gray colors
local function lerpColor(a,b,t)
  return {lerp(a[1],b[1],t),lerp(a[2],b[2],t),lerp(a[3],b[3],t)}
end

function C:init(id)
  self.id = id
  self.visible = false

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
  self.columnId = nil

  self.mode = 'hidden'
  self.oldMode = 'hidden'
  self.modeInfos = deepcopy(modeInfos)

  self.arrowHeightSmoother = newTemporalSpring()
  self.baseArrowScale = 2.0
  self.arrowScaleSmoother = newTemporalSpring(30, 10, self.baseArrowScale)
  self.columnColor = ColorF(1,1,1,1):asLinear4F()
  self.columnAlphaSmoother = newTemporalSpring()
  self.columnAlphaSmoother:set(0.0)
end

function C:update(dt, dtSim)
  self.colorTimer = self.colorTimer + dt
  if self.colorTimer >= self.colorLerpDuration then
    if self.mode == 'hidden' then
      self:hide()
    end
  end
  if not self.visible then return end

  local playerPosition = vec3(0,0,0)
  playerPosition:set(core_camera.getPosition())

  local markerPos2D = vec3(self.pos.x, self.pos.y, 0)
  local playerPos2D = vec3(playerPosition.x, playerPosition.y, 0)
  local distanceFromMarker = markerPos2D:distance(playerPos2D)

  local t = clamp(self.colorTimer / self.colorLerpDuration,0,1)
  local color = lerpColor(self.modeInfos[self.oldMode or 'default'].color, self.modeInfos[self.mode or 'default'].color, t)

  self.currentColor = ColorF(color[1],color[2],color[3],color[4] or 1)
  self.currentColor.a = self.currentColor.a * (clamp(inverseLerp(self.fadeNear,self.fadeFar,distanceFromMarker),0,1))

  if self.flagLeft or self.flagRight then
    local flagOffset = 2.5
    local forwardDir = self.pathDirection:normalized()
    local rightDir = forwardDir:cross(vec3(0, 0, 1)):normalized()

    if self.flagLeft then
      local leftPos = self.pos + rightDir * flagOffset
      local terrainUp = vec3(0, 0, 1)
      if core_terrain then
        local terrainHeight = core_terrain.getTerrainHeight(leftPos)
        if terrainHeight then
          leftPos.z = terrainHeight
        end
        local terrainNormal = core_terrain.getTerrainSmoothNormal(leftPos)
        if terrainNormal then
          terrainUp = terrainNormal
        end
      else
        local surfaceHeight = be:getSurfaceHeightBelow(leftPos + vec3(0, 0, 1))
        if surfaceHeight then
          leftPos.z = surfaceHeight + 0.1
        end
        local surfaceNormal = map.surfaceNormal(leftPos, 1)
        if surfaceNormal then
          terrainUp = surfaceNormal
        end
      end
      self.flagLeft:setPosition(vec3(leftPos))
      local flagRot = quatFromDir(forwardDir, terrainUp)
      self.flagLeft:setField('rotation', 0, flagRot.x .. ' ' .. flagRot.y .. ' ' .. flagRot.z .. ' ' .. flagRot.w)
      self.flagLeft.instanceColor = ColorF(1, 1, 1, self.currentColor.a):asLinear4F()
      self.flagLeft:updateInstanceRenderData()
    end

    if self.flagRight then
      local rightPos = self.pos - rightDir * flagOffset
      local terrainUp = vec3(0, 0, 1)
      if core_terrain then
        local terrainHeight = core_terrain.getTerrainHeight(rightPos)
        if terrainHeight then
          rightPos.z = terrainHeight
        end
        local terrainNormal = core_terrain.getTerrainSmoothNormal(rightPos)
        if terrainNormal then
          terrainUp = terrainNormal
        end
      else
        local surfaceHeight = be:getSurfaceHeightBelow(rightPos + vec3(0, 0, 1))
        if surfaceHeight then
          rightPos.z = surfaceHeight + 0.1
        end
        local surfaceNormal = map.surfaceNormal(rightPos, 1)
        if surfaceNormal then
          terrainUp = surfaceNormal
        end
      end
      self.flagRight:setPosition(vec3(rightPos))
      local flagRot = quatFromDir(forwardDir, terrainUp)
      self.flagRight:setField('rotation', 0, flagRot.x .. ' ' .. flagRot.y .. ' ' .. flagRot.z .. ' ' .. flagRot.w)
      self.flagRight.instanceColor = ColorF(1, 1, 1, self.currentColor.a):asLinear4F()
      self.flagRight:updateInstanceRenderData()
    end
  end

  if self.arrow then
    local fwd = (playerPosition-self.pos)
    local rot = quatFromDir(fwd:z0()):toTorqueQuat()
    self.arrow:setField('rotation', 0, rot.x .. ' ' .. rot.y .. ' ' .. rot.z .. ' ' .. rot.w)

    if self.mode == 'hidden' then
      self.arrow.instanceColor = ColorF(0,0,0,0):asLinear4F()
      self.arrow.instanceColor1 = ColorF(0,0,0,0):asLinear4F()
    else
      self.arrow.instanceColor = self.currentColor:asLinear4F()
      self.arrow.instanceColor1 = ColorF(1,1,1,self.currentColor.a):asLinear4F()
    end

    local currentTime = os.clock()
    self.delay = self.delay - dtSim
    local baseTargetHeight = self.delay < 0 and arrowHeight or arrowStartHeight

    local targetHeight = baseTargetHeight
    if self.mode == 'current' or self.mode == 'recovery' or self.mode == 'bonus' or self.mode == 'final' then
      local testHeight = baseTargetHeight
      local maxTestHeight = 100
      local heightIncrement = 2

      while testHeight <= maxTestHeight do
        local arrowPos = vec3(self.pos.x, self.pos.y, self.pos.z + testHeight)
        local rayDirection = playerPosition - arrowPos
        local rayLength = rayDirection:length()
        if castRayStatic(arrowPos, rayDirection, rayLength, nil) >= rayLength then
          targetHeight = testHeight
          break
        end

        testHeight = testHeight + heightIncrement
      end
    end

    local sinOffset = self.delay < 0 and math.sin(currentTime * 1.9 + self.originalDelay) * 0.4 or 0
    targetHeight = targetHeight + sinOffset

    local currentArrowHeight = self.arrowHeightSmoother:get(targetHeight, dtSim)
    self.arrow:setPosition(vec3(0,0,currentArrowHeight)+self.pos)

    local targetScale = distanceFromMarker < 15.0 and 0.3 or self.baseArrowScale
    -- Scale down finished and inactive markers to reduce visual clutter
    if self.mode == 'finished' or self.mode == 'inactive' then
      targetScale = targetScale * 0.4
    end
    local currentScale = self.arrowScaleSmoother:get(targetScale, dtSim)
    self.arrow:setScale(vec3(currentScale, currentScale, currentScale))
    self.arrow:updateInstanceRenderData()
  end

  if self.columnId then
    local centerColumn = scenetree.findObjectById(self.columnId)
    if centerColumn then
      local targetAlpha = 0.0
      local columnHeight = 200.0

      if distanceFromMarker >= 200.0 then
        if distanceFromMarker >= 300.0 then
          targetAlpha = 1.0
        else
          targetAlpha = clamp(inverseLerp(200.0, 300.0, distanceFromMarker), 0, 1)
        end

        if distanceFromMarker >= 1200.0 then
          columnHeight = 200.0
        else
          columnHeight = lerp(50.0, 200.0, clamp(inverseLerp(200.0, 1200.0, distanceFromMarker), 0, 1))
        end
      end

      local currentAlpha = self.columnAlphaSmoother:get(targetAlpha, dtSim)

      if currentAlpha > 0.01 and self.mode ~= 'hidden' then
        centerColumn.hidden = false
        self.columnColor.x = color[1]
        self.columnColor.y = color[2]
        self.columnColor.z = color[3]
        self.columnColor.w = currentAlpha * 0.95
        centerColumn.instanceColor = self.columnColor
        local columnRadius = self.radius or 2.0
        centerColumn:setScale(vec3(columnRadius, columnRadius, columnHeight))
        centerColumn:updateInstanceRenderData()
      else
        centerColumn.hidden = true
      end
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
    self.arrow:setPosition(vec3(0,0,arrowStartHeight)+self.pos)
  end

  if self.columnId then
    local centerColumn = scenetree.findObjectById(self.columnId)
    if centerColumn then
      centerColumn:setPosition(vec3(self.pos))
      local columnRadius = self.radius or 2.0
      centerColumn:setScale(vec3(columnRadius, columnRadius, 200))
    end
  end
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
  if self.oldMode ~= self.mode then

  end
  self.oldMode = self.mode
  self.mode = mode
  self.colorTimer = 0

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
  if self.columnId then
    local centerColumn = scenetree.findObjectById(self.columnId)
    if centerColumn then
      centerColumn.hidden = not v
    end
  end
end

function C:hide() self:setVisibility(false) end
function C:show() self:setVisibility(true)  end

function C:createObject(shapeName, objectName)
  local marker =  createObject('TSStatic')
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
  if not self.columnId then
    local columnObj = self:createObject(columnShape, columnPrefix..self.id)
    self.columnId = columnObj:getId()
    table.insert(self._ids, self.columnId)
    columnObj.hidden = true
  end
end

function C:clearMarkers()
  for _, id in ipairs(self._ids or {}) do
    local obj = scenetree.findObjectById(id)
    if obj then
      obj:delete()
    end
  end
  self._ids = nil
  self.arrow = nil
  self.flagLeft = nil
  self.flagRight = nil
  self.columnId = nil
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
