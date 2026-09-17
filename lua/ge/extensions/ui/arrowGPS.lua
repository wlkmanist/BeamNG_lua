local M = {}
M.dependencies = {"core_camera"}

local arrow = nil
local arrowId = nil
local arrowScale = 0.04
local defaultColor = {1, 0.4, 0.2}

local upVec = vec3(0, 0, 1)

-- screen position of the app widget (0-1 range), set by the Vue side
local appScreenX = 0.5
local appScreenY = 0.5
local arrowDepth = 0.15

-- priority-based registration: key -> { priority, pos (vec3), color ({r,g,b}) }
local registrations = {}
local activeKey = nil
local activePos = nil
local activeColor = nil

local function resolveActive()
  local bestKey = nil
  local bestPriority = math.huge
  for key, reg in pairs(registrations) do
    if reg.pos and reg.priority < bestPriority then
      bestKey = key
      bestPriority = reg.priority
    end
  end
  activeKey = bestKey
  if bestKey then
    local reg = registrations[bestKey]
    activePos = reg.pos
    activeColor = reg.color or defaultColor
    if arrow then
      local c = activeColor
      arrow:setField('instanceColor', 0, c[1].." "..c[2].." "..c[3].." 1")
      arrow:updateInstanceRenderData()
    end
  else
    activePos = nil
    activeColor = nil
    if arrow then
      if not scenetree.findObjectById(arrowId) then
        arrow = nil
        arrowId = nil
      else
        arrow.hidden = true
      end
    end
  end
end

local function setTarget(key, priority, data)
  data = data or {}
  local pos = data.pos
  if pos then
    pos = vec3(pos.x or pos[1], pos.y or pos[2], pos.z or pos[3])
  end
  registrations[key] = {
    priority = priority,
    pos = pos,
    color = data.color,
  }
  resolveActive()
end

local function removeTarget(key)
  registrations[key] = nil
  resolveActive()
end

local function createArrow()
  if arrow then return end

  arrow = createObject('TSStatic')
  arrow:setField('shapeName', 0, "art/shapes/interface/s_mm_arrow_floating.dae")
  arrow.scale = vec3(arrowScale, arrowScale, arrowScale)
  arrow.useInstanceRenderData = true
  arrow.dynamic = true
  local c = activeColor or defaultColor
  arrow:setField('instanceColor', 0, c[1].." "..c[2].." "..c[3].." 1")
  arrow:setField('collisionType', 0, "None")
  arrow:setField('decalType', 0, "None")
  arrow.canSave = false
  arrow:registerObject(Sim.getUniqueName("arrowGPS"))
  arrowId = arrow:getId()
  arrow.hidden = true
end

local function destroyArrow()
  -- The underlying TSStatic may have already been destroyed by the scene
  if arrowId then
    local obj = scenetree.findObjectById(arrowId)
    if obj then
      obj:delete()
    end
    arrowId = nil
  end
  arrow = nil
end

local function screenToWorld(sx, sy, depth)
  local cam = core_camera
  if not cam then return nil end

  local camPos = cam.getPosition()
  local camForward = cam.getForward()
  local camRight = cam.getRight()
  local camUp = cam.getUp()
  local halfTan = math.tan(math.rad(cam.getFovDeg()) * 0.5)

  local res = GFXDevice.getVideoMode()
  local aspect = 1
  if res and res.width and res.height and res.height > 0 then
    aspect = res.width / res.height
  end

  local nx = sx * 2 - 1
  local ny = 1 - sy * 2

  return camPos
    + camForward * depth
    + camRight * (nx * depth * halfTan * aspect)
    + camUp * (ny * depth * halfTan)
end

local function setAppScreenPos(sx, sy)
  appScreenX = sx
  appScreenY = sy
end

local function setScale(scale)
  arrowScale = scale
  if arrow then
    arrow.scale = vec3(scale, scale, scale)
  end
end

local function setDepth(depth)
  arrowDepth = depth
end

local function onPreRender(dt)
  if not arrow then return end
  if not scenetree.findObjectById(arrowId) then
    arrow = nil
    arrowId = nil
    return
  end

  local playerVehicle = getPlayerVehicle(0)
  if not playerVehicle or not activePos then
    arrow.hidden = true
    return
  end

  local arrowPos = screenToWorld(appScreenX, appScreenY, arrowDepth)
  if not arrowPos then
    arrow.hidden = true
    return
  end

  local toTarget = activePos - arrowPos

  if toTarget:length() < 0.1 then
    arrow.hidden = true
    return
  end

  local toTargetDir = vec3(toTarget)
  toTargetDir:normalize()
  local right = toTargetDir:cross(upVec)
  right:normalize()
  local rot = quatFromDir(toTargetDir, right)

  arrow:setPosRot(arrowPos.x, arrowPos.y, arrowPos.z, rot.x, rot.y, rot.z, rot.w)
  arrow.hidden = false
end

local function onExtensionLoaded()
  createArrow()
end

local function onExtensionUnloaded()
  destroyArrow()
  registrations = {}
  activeKey = nil
  activePos = nil
  activeColor = nil
end

M.setTarget = setTarget
M.removeTarget = removeTarget
M.setAppScreenPos = setAppScreenPos
M.setScale = setScale
M.setDepth = setDepth
M.onPreRender = onPreRender
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
