-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local highlightedTriggersByVehicle = {}
local debugTimer = 0
local CIRCLE_SEGMENTS = 48
local WORLD_UP = vec3(0, 0, 1)
local WORLD_Y = vec3(0, 1, 0)
local WORLD_X = vec3(1, 0, 0)
local TMP_CIRCLE_NORMAL = vec3()
local TMP_CIRCLE_TANGENT = vec3()
local TMP_CIRCLE_BITANGENT = vec3()
local TMP_CIRCLE_P0 = vec3()
local TMP_CIRCLE_P1 = vec3()

local LINE_COLOR = ColorF(1, 1, 1, 0.75)
local SPHERE_COLOR = ColorF(0.235, 0.396, 1, 0.75)
local BOX_COLOR = ColorF(0.235, 0.396, 1, 0.75)

local function drawAxisBox(corner, x, y, z, clr)
  -- draw all faces in a loop
  for _, face in ipairs({{x, y, z}, {x, z, y}, {y, z, x}}) do
    local a, b, c = face[1], face[2], face[3]
    -- spokes
    debugDrawer:drawLine((corner), (corner + c), LINE_COLOR)
    debugDrawer:drawLine((corner + a), (corner + c + a), LINE_COLOR)
    debugDrawer:drawLine((corner + b), (corner + c + b), LINE_COLOR)
    debugDrawer:drawLine((corner + a + b), (corner + c + a + b), LINE_COLOR)
    -- first side
    debugDrawer:drawTriSolid(
      vec3(corner),
      vec3(corner + a),
      vec3(corner + a + b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(corner + b),
      vec3(corner),
      vec3(corner + a + b),
      clr)
    -- back of first side
    debugDrawer:drawTriSolid(
      vec3(corner + a),
      vec3(corner),
      vec3(corner + a + b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(corner),
      vec3(corner + b),
      vec3(corner + a + b),
      clr)
    -- other side
    debugDrawer:drawTriSolid(
      vec3(c + corner),
      vec3(c + corner + a),
      vec3(c + corner + a + b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(c + corner + b),
      vec3(c + corner),
      vec3(c + corner + a + b),
      clr)
    -- back of other side
    debugDrawer:drawTriSolid(
      vec3(c + corner + a),
      vec3(c + corner),
      vec3(c + corner + a + b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(c + corner),
      vec3(c + corner + b),
      vec3(c + corner + a + b),
      clr)
  end
end

local function drawCameraFacingCircle(center, radius)
  if radius <= 0 then return end
  local camPos = core_camera and core_camera.getPosition and core_camera.getPosition() or nil
  if not camPos then return end

  TMP_CIRCLE_NORMAL:setSub2(camPos, center)
  if TMP_CIRCLE_NORMAL:length() < 1e-6 then
    TMP_CIRCLE_NORMAL:set(0, 0, 1)
  else
    TMP_CIRCLE_NORMAL:normalize()
  end

  local refUp = WORLD_UP
  if math.abs(TMP_CIRCLE_NORMAL:dot(refUp)) > 0.98 then
    refUp = WORLD_Y
  end

  TMP_CIRCLE_TANGENT:setCross(refUp, TMP_CIRCLE_NORMAL)
  if TMP_CIRCLE_TANGENT:length() < 1e-6 then
    TMP_CIRCLE_TANGENT:setCross(WORLD_X, TMP_CIRCLE_NORMAL)
  end
  TMP_CIRCLE_TANGENT:normalize()

  TMP_CIRCLE_BITANGENT:setCross(TMP_CIRCLE_NORMAL, TMP_CIRCLE_TANGENT)
  TMP_CIRCLE_BITANGENT:normalize()

  for i = 0, CIRCLE_SEGMENTS - 1 do
    local a0 = (i / CIRCLE_SEGMENTS) * math.pi * 2
    local a1 = ((i + 1) / CIRCLE_SEGMENTS) * math.pi * 2
    local c0 = math.cos(a0) * radius
    local s0 = math.sin(a0) * radius
    local c1 = math.cos(a1) * radius
    local s1 = math.sin(a1) * radius

    TMP_CIRCLE_P0:setAddScaled(center, TMP_CIRCLE_TANGENT, c0)
    TMP_CIRCLE_P0:setAddScaled(TMP_CIRCLE_P0, TMP_CIRCLE_BITANGENT, s0)
    TMP_CIRCLE_P1:setAddScaled(center, TMP_CIRCLE_TANGENT, c1)
    TMP_CIRCLE_P1:setAddScaled(TMP_CIRCLE_P1, TMP_CIRCLE_BITANGENT, s1)
    debugDrawer:drawLine(TMP_CIRCLE_P0, TMP_CIRCLE_P1,LINE_COLOR)
  end
end

local function computeBoxAxesAndExtents(vehicleObj, triggerData)
  local basisX, basisY, basisZ, hx, hy, hz = core_vehicle_triggerLabelPlacement.computeTriggerBasisAndHalfExtents(vehicleObj, triggerData)
  return basisX, basisY, basisZ, hx * 2, hy * 2, hz * 2
end

local function getVehicleTriggerSet(vehId)
  local key = tostring(vehId)
  local set = highlightedTriggersByVehicle[key]
  if not set then
    set = {}
    highlightedTriggersByVehicle[key] = set
  end
  return set
end

local function hasAnyHighlightedTriggers()
  return next(highlightedTriggersByVehicle) ~= nil
end

local function clearAllHighlights()
  highlightedTriggersByVehicle = {}
end

local function normalizeHighlightOptions(options)
  local opts = options
  if type(opts) ~= "table" then
    opts = {}
  end
  return {
    showTriggerIdAsLabel = opts.showTriggerIdAsLabel ~= false,
  }
end

function M.isHighlightedTrigger(vehId, triggerId)
  if vehId == nil or triggerId == nil then return false end
  local set = highlightedTriggersByVehicle[tostring(vehId)]
  return set and set[tostring(triggerId)] ~= nil or false
end

function M.setHighlightedTrigger(vehId, triggerId, options)
  if vehId == nil or triggerId == nil then return end
  local set = getVehicleTriggerSet(vehId)
  set[tostring(triggerId)] = normalizeHighlightOptions(options)
end

local function getTriggerCidByName(vehId, triggerName)
  if vehId == nil or triggerName == nil then return nil end
  local vData = extensions.core_vehicle_manager.getVehicleData(vehId)
  local triggers = vData and vData.vdata and vData.vdata.triggers
  if type(triggers) ~= "table" then return nil end

  local wanted = tostring(triggerName)
  for _, triggerData in pairs(triggers) do
    if triggerData.name == triggerName
      or triggerData.id == triggerName
      or tostring(triggerData.name) == wanted
      or tostring(triggerData.id) == wanted
      or tostring(triggerData.cid) == wanted then
      return triggerData.cid
    end
  end
  return nil
end

function M.setHighlightedTriggerByName(vehId, triggerName, options)
  local triggerCid = getTriggerCidByName(vehId, triggerName)
  if triggerCid == nil then return false end
  M.setHighlightedTrigger(vehId, triggerCid, options)
  return true
end

function M.unhighlightTrigger(vehId, triggerId)
  if vehId == nil or triggerId == nil then return end
  local vehKey = tostring(vehId)
  local set = highlightedTriggersByVehicle[vehKey]
  if not set then return end
  set[tostring(triggerId)] = nil
  if next(set) == nil then
    highlightedTriggersByVehicle[vehKey] = nil
  end
end

function M.clearHighlightedTrigger()
  clearAllHighlights()
end

function M.getSerializedHighlightedTriggerData()
  local out = {}
  for vehKey, triggerSet in pairs(highlightedTriggersByVehicle) do
    local vehId = tonumber(vehKey) or vehKey
    for triggerKey, options in pairs(triggerSet) do
      local triggerId = tonumber(triggerKey) or triggerKey
      local opts = normalizeHighlightOptions(options)
      out[#out + 1] = {vehId, triggerId, opts}
    end
  end
  return out
end

function M.setSerializedHighlightedTriggerData(data)
  clearAllHighlights()
  if type(data) ~= "table" then return end
  -- Backward compatibility: single legacy tuple {vehId, triggerId}
  if data[1] ~= nil and data[2] ~= nil and type(data[1]) ~= "table" then
    M.setHighlightedTrigger(data[1], data[2], data[3])
    return
  end
  for _, entry in pairs(data) do
    if type(entry) == "table" and entry[1] ~= nil and entry[2] ~= nil then
      M.setHighlightedTrigger(entry[1], entry[2], entry[3])
    end
  end
end

local function drawOneHighlightedTrigger(highLightedTriggerVehId, highLightedTriggerId, options)
  local vData = extensions.core_vehicle_manager.getVehicleData(highLightedTriggerVehId)
  local veh = getObjectByID(highLightedTriggerVehId)
  if veh and vData and vData.vdata.triggers then
    local trg = vData.vdata.triggers[highLightedTriggerId]
    local triggerObj = veh:getTrigger(highLightedTriggerId)
    if trg and triggerObj then
      local pos = triggerObj:getCenter()
      local col = SPHERE_COLOR
      local triggerType = type(trg.type) == "string" and string.lower(trg.type) or nil
      local isSphereTrigger = triggerType == "sphere" or (triggerType == nil and type(trg.size) == "number")
      local isBoxTrigger = triggerType == "box" or (triggerType == nil and type(trg.size) == "table")
      local r = 0.1
      if type(trg.size) == "number" then
        r = trg.size
      elseif type(trg.radius) == "number" then
        r = trg.radius
      elseif type(trg.size) == "table" and trg.size.x and trg.size.y and trg.size.z then
        r = math.sqrt(trg.size.x ^ 2 + trg.size.y ^ 2 + trg.size.z ^ 2) / 2
      end
      col.alpha = 0.3 * math.sin(debugTimer * math.pi * 2) + 0.5
      if isSphereTrigger then
        debugDrawer:drawSphere(pos, r, col)
        drawCameraFacingCircle(pos, r)
      elseif isBoxTrigger then
        local basisX, basisY, basisZ, sx, sy, sz = computeBoxAxesAndExtents(veh, trg)
        local x = basisX * sx
        local y = basisY * sy
        local z = basisZ * sz
        local corner = pos - ((x + y + z) * 0.5)
        local alpha255 = math.max(0, math.min(255, math.floor((col.alpha or 1) * 255)))
        local col = color(BOX_COLOR.r * 255, BOX_COLOR.g * 255, BOX_COLOR.b * 255, alpha255)
        drawAxisBox(corner, x, y, z, col)
      end
      local opts = normalizeHighlightOptions(options)
      if opts.showTriggerIdAsLabel then
        local text = tostring(highLightedTriggerId) .. ' - ' .. tostring(trg.name) .. ' [' .. tostring(trg.originSection or 'triggers') .. ']'
        debugDrawer:drawTextAdvanced(pos, String(text), ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 192))
      end
    end
  end
end

function M.onUpdate(dt)
  if not hasAnyHighlightedTriggers() then return end
  debugTimer = debugTimer + (dt or 0)
  if debugTimer > 1000 then debugTimer = debugTimer - 1000 end
  for vehKey, triggerSet in pairs(highlightedTriggersByVehicle) do
    local vehId = tonumber(vehKey) or vehKey
    for triggerKey, options in pairs(triggerSet) do
      local triggerId = tonumber(triggerKey) or triggerKey
      drawOneHighlightedTrigger(vehId, triggerId, options)
    end
  end
end

return M
