-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "freeformDelivery_hints"

local p = nil -- Profiler instance (assigned in update function)

local hints = {}
local activeDelivery = nil
local activeHintIds = {} -- Track which hints are currently shown

local Text = {
  hint = "missions.freeformDelivery.common.hint.fallback",
}

local function translateText(text)
  if text == nil then return nil end
  if core_locales and core_locales.translateWithOrWithoutContext then
    return core_locales.translateWithOrWithoutContext(text)
  end
  if type(text) == "table" and text.txt then
    return _tr(text.txt)
  end
  if type(text) == "string" then
    return _tr(text)
  end
  return text
end

-- Reusable temporary vectors to avoid allocations
local tempVec3_1 = vec3()
local tempVec3_2 = vec3()
local tempQuat = quat()

local function isPlayerInArea(delivery, targetAreaId)
  local playerPos = gameplay_freeformDelivery_utils.getPlayerPosition()
  if not playerPos then return false end

  local targetArea = gameplay_freeformDelivery_utils.findTargetArea(delivery, targetAreaId)
  if not targetArea then return false end

  local siteObj = gameplay_freeformDelivery_utils.findSiteObject(delivery.sites, targetArea.type, targetArea.siteId)
  if not siteObj then return false end

  -- If player is in a vehicle, use optimized vehicle check
  local veh = gameplay_freeformDelivery_utils.getPlayerVehicle()
  if veh then
    return gameplay_freeformDelivery_utils.checkVehicleInArea(veh, siteObj, targetArea.type)
  end

  -- For walking players, use manual checks
  if targetArea.type == "zone" then
    if siteObj.containsPoint2D then
      return siteObj:containsPoint2D(playerPos)
    end
    return false
  elseif targetArea.type == "location" then
    -- Use squared distance to avoid allocation (distance() might allocate)
    tempVec3_1:set(playerPos)
    tempVec3_1:setSub(siteObj.pos)
    local distSq = tempVec3_1:lengthSq()
    local radiusSq = siteObj.radius * siteObj.radius
    return distSq <= radiusSq
  elseif targetArea.type == "parkingSpot" then
    -- For walking players, check parking spot manually
    local spotPos = siteObj.pos
    local spotScale = siteObj.scl
    local halfSizeX = spotScale.x / 2
    local halfSizeY = spotScale.y / 2
    local halfSizeZ = spotScale.z / 2

    -- Calculate difference (reuse tempVec3_1)
    tempVec3_1:set(playerPos)
    tempVec3_1:setSub(spotPos)

    -- Transform to local space (reuse tempVec3_2 for result)
    tempQuat:set(siteObj.rot)
    tempQuat:inverse()
    tempVec3_2:set(tempVec3_1)
    tempVec3_2:setRotate(tempQuat)

    return math.abs(tempVec3_2.x) <= halfSizeX and
           math.abs(tempVec3_2.y) <= halfSizeY and
           math.abs(tempVec3_2.z) <= halfSizeZ
  end

  return false
end

function M.setup(delivery)
  if not delivery then return end

  activeDelivery = delivery
  hints = {}
  activeHintIds = {}

  -- Load hints from delivery data
  for _, hintData in ipairs(delivery.hints or {}) do
    if not hintData.id then
      log('W', logTag, 'Hint missing required id field')
      goto continue
    end

    if not hintData.targetAreaIds or #hintData.targetAreaIds == 0 then
      log('W', logTag, 'Hint missing targetAreaIds: ' .. hintData.id)
      goto continue
    end

    hints[hintData.id] = {
      id = hintData.id,
      targetAreaIds = hintData.targetAreaIds,
      message = hintData.message or Text.hint,
      subtext = hintData.subtext
    }

    ::continue::
  end

  local hintCount = 0
  for _ in pairs(hints) do
    hintCount = hintCount + 1
  end
  log('I', logTag, string.format('Loaded %d hints', hintCount))
end

function M.update(dtReal, dtSim, dtRaw, profiler)
  p = profiler -- Assign to module-level variable for local functions

  if not activeDelivery then return end

  if p then p:add("hints initialization") end

  local playerPos = gameplay_freeformDelivery_utils.getPlayerPosition()
  if p then p:add("get player position") end
  if not playerPos then return end

  -- Check each hint
  for hintId, hint in pairs(hints) do
    if p then p:add("hint loop: " .. hintId) end

    local isInAnyArea = false

    -- Check if player is in any of the hint's target areas
    for _, targetAreaId in ipairs(hint.targetAreaIds) do
      if isPlayerInArea(activeDelivery, targetAreaId) then
        isInAnyArea = true
      end
      if p then p:add("player in area: " .. targetAreaId) end
      if isInAnyArea then break end
    end

    local isCurrentlyShown = activeHintIds[hintId] ~= nil

    if isInAnyArea and not isCurrentlyShown then
      -- Show hint
      guihooks.trigger("SetTasklistTask", {
        id = "hint_" .. hintId,
        type = "message",
        label = translateText(hint.message),
        subtext = translateText(hint.subtext),
        done = false,
        fail = false
      })
      activeHintIds[hintId] = true
      if p then p:add("show hint: " .. hintId) end
    elseif not isInAnyArea and isCurrentlyShown then
      -- Hide hint
      guihooks.trigger("DiscardTasklistItem", "hint_" .. hintId)
      activeHintIds[hintId] = nil
      if p then p:add("hide hint: " .. hintId) end
    end
  end

  if p then p:add("hints loop complete") end
end

function M.cleanup()
  -- Remove all active hints
  for hintId, _ in pairs(activeHintIds) do
    guihooks.trigger("DiscardTasklistItem", "hint_" .. hintId)
  end

  hints = {}
  activeDelivery = nil
  activeHintIds = {}
end

return M
