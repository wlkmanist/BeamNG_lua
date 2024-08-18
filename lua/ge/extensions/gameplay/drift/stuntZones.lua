local M = {}

local driftActiveData = {}
local isDrifting

local white = ColorF(1, 1, 1, 1) -- White
local green = ColorF(0.4, 1, 0.43, 1) -- Green
local red = ColorF(1, 0.07, 0.14, 1) -- Red
local blue = ColorF(0.2, 0.9, 1, 1) -- Blue

local stuntZones = {}
-- {
--   id = x,
--   type = "donut",
--   zoneData = {
--     cooldown = x,
--     scl = x,
--     txt = "x",
--     pos = vec(x,x,x)
--   },
--   funcs = {},
--   activeData = {
--     currCooldown = x,
--   },
--   drawData = {}
-- }

local decals = {}
local count = 0

local decalCount = 180
local defaultDecalScale = vec3(0.35,0.35,3)
local defaultDecalPath = "art/shapes/arrows/t_arrow_opaque_d.color.png"
local t, cosX, sinY, x, y, data, invAmount, filledPerc, cooldownPerc

local function increaseDecalPool(max)
  while #decals < max do
    table.insert(decals,
    {
      texture = defaultDecalPath,
      position = vec3(0, 0, 0),
      forwardVec = vec3(0, 0, 0),
      color = ColorF(1, 0, 0, 1 ),
      scale = vec3(1, 1, 4),
      fadeStart = 100,
      fadeEnd = 150
    })
  end
end

local function getDecalColor(cooldownPerc, filledPerc, t)
  if (cooldownPerc or 100) >= 100 then
    if (filledPerc or 0) > 0 then
      if ((t * 100) or (100 - t * 100)) < (filledPerc or 0) then
        return blue
      else
        return green
      end
    else
      return green
    end
  else
    if ((t * 100) or (100 - t * 100)) <= (100 - cooldownPerc or 0) then
      return red
    else
      return white
    end
  end
end

local function drawDonutZone(stuntZone)
  filledPerc = stuntZone.activeData.totalDriftAngle / 360 * 100
  cooldownPerc = 100 - stuntZone.activeData.currCooldown / stuntZone.zoneData.cooldown * 100

  decalCount = stuntZone.drawData.decalCount
  invAmount = 1/decalCount
  increaseDecalPool(decalCount+1)

  for i = 0, decalCount do
    t = i*invAmount

    cosX = math.cos(math.rad(t * 360))
    sinY = math.sin(math.rad(t * 360))

    x = (stuntZone.zoneData.pos.x or 0) + ((stuntZone.zoneData.scl or 1) * cosX)
    y = (stuntZone.zoneData.pos.y or 0) + ((stuntZone.zoneData.scl or 1) * sinY)

    data = decals[i+1]

    data.color = getDecalColor(cooldownPerc, filledPerc, t)
    data.position:set(x,y,stuntZone.zoneData.pos.z or 0)
    data.forwardVec:set(cosX, sinY, 1)
    data.texture = defaultDecalPath
    data.scale:set(defaultDecalScale.x,defaultDecalScale.y,defaultDecalScale.z)
  end
  Engine.Render.DynamicDecalMgr.addDecals(decals, decalCount)
end

local a, b
local fwd = vec3()
local lerpVec = vec3()
local function drawDriftThroughZone(stuntZone)
  decalCount = stuntZone.drawData.decalCount
  cooldownPerc = 100 - stuntZone.activeData.currCooldown / stuntZone.zoneData.cooldown * 100

  local invAmount = 1/decalCount
  increaseDecalPool(decalCount+1)

  for i = 1, 2 do
    if i == 1 then
      a, b  = stuntZone.drawData.pointA, stuntZone.drawData.pointB
    else
      a, b  = stuntZone.drawData.pointC, stuntZone.drawData.pointD
    end

    fwd:set((b-a):normalized())
    for i = 0, decalCount do
      t = i*invAmount
      data = decals[i+1]
      lerpVec = lerp(a, b, t)
      data.color = getDecalColor(cooldownPerc, 0, t)
      data.position:set(lerpVec.x, lerpVec.y, lerpVec.z)
      data.forwardVec:set(fwd.x, fwd.y, fwd.z)
      data.texture = defaultDecalPath
      data.scale:set(defaultDecalScale.x,defaultDecalScale.y,defaultDecalScale.z)
    end

    Engine.Render.DynamicDecalMgr.addDecals(decals, decalCount)
  end
end

local function isDonutZoneActive(stuntZone)
  stuntZone.activeData.isActive = gameplay_drift_drift.getVehPos():distance(stuntZone.zoneData.pos) < stuntZone.zoneData.scl
  if not stuntZone.activeData.isActive then
    stuntZone.activeData.totalDriftAngle = 0
  end
end

local function isDriftThroughZoneActive(stuntZone)
  stuntZone.activeData.isActive = containsOBB_point(stuntZone.zoneData.pos, stuntZone.x, stuntZone.y, stuntZone.z, gameplay_drift_drift.getVehPos())
  if not stuntZone.activeData.isActive then
    stuntZone.activeData.usedFlag = true
  end
end

local function manageCooldown(stuntZone, dtSim)
  if not stuntZone.activeData.currCooldown then return end -- if this stunt zone doesn't have a cooldown

  if stuntZone.activeData.currCooldown > 0 then
    stuntZone.activeData.currCooldown = stuntZone.activeData.currCooldown - dtSim
  end
end

local x, y ,z
local function detectDriftThrough(stuntZone)
  if stuntZone.activeData.usedFlag then
    extensions.hook('onDriftThroughDetected', driftActiveData.currDegAngle)
    stuntZone.activeData.usedFlag = false

    stuntZone.activeData.currCooldown = stuntZone.zoneData.cooldown
  end
end

local function detectDonut(stuntZone)
  stuntZone.activeData.totalDriftAngle = stuntZone.activeData.totalDriftAngle + gameplay_drift_drift.getAngleDiff()
  local totalDonuts = math.floor(stuntZone.activeData.totalDriftAngle / 360)

  if stuntZone.activeData.totalDriftAngle >= 360 then
    extensions.hook('onDonutDriftDetected')

    stuntZone.activeData.totalDriftAngle = 0
    stuntZone.activeData.currCooldown = stuntZone.zoneData.cooldown
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if gameplay_drift_general.getContext() == "stopped" then return end

  driftActiveData = gameplay_drift_drift.getDriftActiveData()
  isDrifting = gameplay_drift_drift.getIsDrifting()

  for _, stuntZone in ipairs(stuntZones) do
    if isDrifting then
      if stuntZone.funcs.detectIfActiveFunc then stuntZone.funcs.detectIfActiveFunc(stuntZone) end
      if stuntZone.funcs.detectStuntFunc and stuntZone.activeData.isAvailable() and stuntZone.activeData.isActive then
        stuntZone.funcs.detectStuntFunc(stuntZone)
      end
    end
    if stuntZone.funcs.drawFunc then stuntZone.funcs.drawFunc(stuntZone) end
    manageCooldown(stuntZone, dtSim)
  end
end

local function clearStuntZones()
  stuntZones = {}
  decals = {}
end

local function getNewDonutActiveData(sanitizedStuntZone)
  return {
    isActive = false,
    currCooldown = 0,
    totalDriftAngle = 0, -- donut counting will use that
    isAvailable = function() return sanitizedStuntZone.activeData.currCooldown <= 0 end,
    completedPerc = 0,
    reset = function() getNewDonutActiveData(sanitizedStuntZone) end
  }
end

local function getNewDriftThroughActiveData(sanitizedStuntZone)
  return {
    isActive = false,
    currCooldown = 0,
    usedFlag = false,
    isAvailable = function() return sanitizedStuntZone.activeData.currCooldown <= 0 end,
    reset = function() getNewDriftThroughActiveData(sanitizedStuntZone) end
  }
end

local function setStuntZones(zones)
  clearStuntZones()

  local sanitizedStuntZones = {}
  for _, stuntZone in ipairs(zones) do -- assign different function depending on the stunt zone type
    local sanitizedStuntZone = {}
    sanitizedStuntZone.zoneData = stuntZone

    if stuntZone.type == "donut" then
      sanitizedStuntZone.funcs = {
        drawFunc = drawDonutZone,
        detectStuntFunc = detectDonut,
        detectIfActiveFunc = isDonutZoneActive
      }
      sanitizedStuntZone.activeData = getNewDonutActiveData(sanitizedStuntZone)
      sanitizedStuntZone.drawData = {
        decalCount = stuntZone.scl * 19,
      }
    elseif stuntZone.type == "driftThrough" then
      sanitizedStuntZone.funcs = {
        drawFunc = drawDriftThroughZone,
        detectStuntFunc = detectDriftThrough,
        detectIfActiveFunc = isDriftThroughZoneActive
      }
      sanitizedStuntZone.activeData = getNewDriftThroughActiveData(sanitizedStuntZone)

      sanitizedStuntZone.x = stuntZone.rot* vec3(stuntZone.scl.x,0,0)
      sanitizedStuntZone.y = stuntZone.rot * vec3(0,stuntZone.scl.y,0)
      sanitizedStuntZone.z = stuntZone.rot * vec3(0,0,stuntZone.scl.z)

      local pointOne = stuntZone.pos + sanitizedStuntZone.x + sanitizedStuntZone.y
      local pointTwo = stuntZone.pos + sanitizedStuntZone.x - sanitizedStuntZone.y
      local pointThree = stuntZone.pos - sanitizedStuntZone.x + sanitizedStuntZone.y
      local pointFour = stuntZone.pos - sanitizedStuntZone.x - sanitizedStuntZone.y

      if pointOne:distance(pointThree) < pointOne:distance(pointTwo) then
        sanitizedStuntZone.drawData = {
          pointA = pointOne,
          pointB = pointTwo,
          pointC = pointThree,
          pointD = pointFour,
        }
      else
        sanitizedStuntZone.drawData = {
          pointA = pointTwo,
          pointB = pointFour,
          pointC = pointOne,
          pointD = pointThree,
        }
      end
      sanitizedStuntZone.drawData.decalCount = sanitizedStuntZone.drawData.pointA:distance(sanitizedStuntZone.drawData.pointB) * 8.5
    end
    table.insert(sanitizedStuntZones, sanitizedStuntZone)
  end

  stuntZones = sanitizedStuntZones
end

local function resetStuntZones()
  for _, stuntZone in ipairs(stuntZones) do
    stuntZone.activeData.reset()
  end
end

local function onDriftStatusChanged(status)
  if not status then
    for _, stuntZone in ipairs(stuntZones) do
      if stuntZone.zoneData.type == "donut" then
        stuntZone.activeData.totalDriftAngle = 0
      end
    end
  end
end

M.onUpdate = onUpdate
M.onDriftStatusChanged = onDriftStatusChanged

M.clearStuntZones = clearStuntZones
M.resetStuntZones = resetStuntZones
M.setStuntZones = setStuntZones
return M