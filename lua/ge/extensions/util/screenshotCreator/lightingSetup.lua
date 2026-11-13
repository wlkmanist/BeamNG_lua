-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"util_screenshotCreator_settings", "util_screenshotCreator_vehicleSetup"}

local ssaoModule = require("client/postFx/ssao")

local logTag = "screenshotCreatorLighting"
local lightplaneShapeSuffix = "/art/shapes/lightplanes/lightplane_a.dae"
local lightplaneHalfSize = 2
local roleFieldName = "thumbnailRole"
local markupFieldName = "thumbnailLayer"
local markupLayerName = "parkingMarkup"
local occupantMeshKinds = {character_torso = true, character_head = true}
local reflectionRenderViewMaskBit = 63
-- BeamNGVehicle renders its reflection cubemap from getPosition() + (0, 0, 1) without parallax correction,
-- so a card only needs the right direction and angular size as seen from that point
local probeHeightOffset = 1
local spotlightClearance = 10
local spotlightNearDistance = 0.8
local cardClearance = 6
local cardMinDistance = 10
local cameraCardBehindDistance = 1
local lightClearance = 8
local lightMinDistance = 12
-- large assets move out with their size so the near/far falloff across the body stays close to a sedan's
local lightDistanceScale = 3
local lightPoolMargin = 2
local coneMargin = 20
local floorClearance = 0.05
local reducedSsaoContrast = 1
local worldUp = vec3(0, 0, 1)
local lightFieldNames = {"intensity", "innerAngle", "outerAngle", "range", "castShadows"}

-- normal: body normal to light, tilted toward the camera ("up") or upward ("cameraSide"); "camera" faces the lens
-- width/height: angular size seen from the probe; the emissive gradient is only bright around its center
local cardRoles = {
  horizonCard = {normal = "up", tilt = 5, width = 110, height = 24},
  shoulderCard = {normal = "cameraSide", tilt = 15, width = 100, height = 16},
  topCard = {normal = "up", tilt = 40, width = 70, height = 36},
  cameraCard = {normal = "camera", width = 40, height = 20},
}
local cardRoleOrder = {"horizonCard", "shoulderCard", "topCard", "cameraCard"}

-- azimuth: degrees from the camera direction toward the vehicle rear, negative toward the front
-- lux: illuminance at the aim point; exposure is 2^-EV, so 1000 lx keeps an 18% grey card at 0.18 under EV 8.3
-- aim "groundCameraSide": the floor under the camera-side edge of the OOBB instead of the vehicle center
-- aim "horizon": fills the floor between the vehicle and the backdrop horizon. It hangs past the far side of the
-- vehicle and its key shadow (at least minOffset from the center) and tilts away by half its cone, so the near cone
-- edge is vertical and the vehicle and its shadow get no light from it; lux is measured on the cone axis, range fades
-- it out toward the backdrop
local lightRoles = {
  key = {azimuth = -20, elevation = 30, lux = 1000},
  fill = {azimuth = 60, elevation = 40, lux = 400},
  rim = {azimuth = 150, elevation = 30, lux = 500},
  top = {elevation = 90, lux = 500},
  groundFill = {azimuth = 40, elevation = 35, lux = 300, aim = "groundCameraSide"},
  horizonFill = {lux = 1500, height = 20, innerAngle = 30, outerAngle = 90, range = 80, minOffset = 5, aim = "horizon"},
}
local lightRoleOrder = {"key", "fill", "rim", "top", "groundFill", "horizonFill"}

-- exposure correction scales these roles so the camera-visible OOBB faces receive exposureTarget lx in total;
-- groundFill and non-rig lights stay fixed so the floor and backdrop look the same for every asset.
-- exposureTarget is calibrated on bastion base_v6_A, which the correction leaves at gain ~1
local exposureRoles = {key = true, fill = true, rim = true, top = true}
local exposureTarget = 850
local exposureMinGain = 0.5
local exposureMaxGain = 2
local exposureSampleSteps = {-0.8, -0.4, 0, 0.4, 0.8}

local activeLightStates = {}
local activeCardStates = {}
local activeTechCardVisibilityStates = {}
local mainViewMaskSet = false
local activeSsaoState
local activeMarkupStates = {}
local activeOccupantState
local selfChecked = false

local function isLightplane(object)
  local shapeName = tostring(object:getField("shapeName", 0) or ""):gsub("\\", "/"):lower()
  return shapeName:sub(-#lightplaneShapeSuffix) == lightplaneShapeSuffix
end

local function vectorsClose(left, right)
  return (left - right):squaredLength() <= 0.00000001
end

local function transformsClose(actual, expected)
  for index = 0, 3 do
    if not vectorsClose(actual:getColumn(index), expected:getColumn(index)) then return false end
  end
  return true
end

local function transformMatches(object, expected)
  return transformsClose(object:getTransform(), expected)
end

local function getCurrentCardObject(state)
  return scenetree.findObjectById(state.id)
end

local function setLightFields(object, fields)
  for name, value in pairs(fields) do
    object:setField(name, 0, tostring(value))
  end
  if object.postApply then object:postApply() end
end

local function rememberLightState(object)
  local id = object:getID()
  if activeLightStates[id] then return activeLightStates[id] end
  local fields = {}
  for _, name in ipairs(lightFieldNames) do fields[name] = object:getField(name, 0) end
  local state = {
    object = object,
    transform = object:getTransform() * MatrixF(true),
    fields = fields
  }
  activeLightStates[id] = state
  return state
end

local function setMainViewCardMask(enabled)
  local mainView = RenderViewManagerInstance and RenderViewManagerInstance:getView("main") or nil
  if not mainView then return end
  if enabled then
    mainView:maskSet(reflectionRenderViewMaskBit)
    mainViewMaskSet = true
  elseif mainViewMaskSet then
    mainView:maskClear()
    mainViewMaskSet = false
  end
end

local function applySsaoMode(mode)
  local ssao = scenetree.findObject("SSAOPostFx")
  if not ssao or mode == "on" then return end
  activeSsaoState = {enabled = ssao:isEnabled(), contrast = ssaoModule.getContrast()}
  if mode == "off" then
    ssao:disable()
  else
    ssaoModule.setContrast(reducedSsaoContrast)
  end
end

local function restoreSsao()
  local state = activeSsaoState
  if not state then return end
  activeSsaoState = nil
  local ssao = scenetree.findObject("SSAOPostFx")
  if not ssao then return end
  ssaoModule.setContrast(state.contrast)
  if state.enabled then ssao:enable() else ssao:disable() end
end

local function setMarkupFlags(object, hidden, renderEnabled)
  if object:isHidden() == hidden and object:isRenderEnabled() == renderEnabled then return end
  local editorDirty = object.isEditorDirty and object:isEditorDirty() or false
  if object:isHidden() ~= hidden then object:setHidden(hidden) end
  if object:isRenderEnabled() ~= renderEnabled then object:setRenderEnabled(renderEnabled) end
  if object.setEditorDirty then object:setEditorDirty(editorDirty) end
end

local function applyMarkupVisibility(objects, shown)
  for _, object in ipairs(objects) do
    activeMarkupStates[#activeMarkupStates + 1] = {
      object = object,
      hidden = object:isHidden(),
      renderEnabled = object:isRenderEnabled()
    }
    setMarkupFlags(object, not shown, shown)
  end
end

local function restoreMarkup()
  for _, state in ipairs(activeMarkupStates) do
    local ok, err = pcall(function()
      setMarkupFlags(state.object, state.hidden, state.renderEnabled)
    end)
    if not ok then log("E", logTag, "Unable to restore parking markup: " .. tostring(err)) end
  end
  activeMarkupStates = {}
end

-- duplicated seats rename the mesh (character_torsoD), so match on originalMesh
local function hideOccupants(vehicle)
  local vehicleData = core_vehicle_manager.getVehicleData(vehicle:getId())
  local vdata = vehicleData and vehicleData.vdata
  if not vdata then return end
  local meshes = {}
  for _, list in ipairs({vdata.flexbodies or {}, vdata.props or {}}) do
    for _, meshData in pairs(list) do
      local mesh = meshData.mesh
      if mesh and not meshes[mesh] and occupantMeshKinds[meshData.originalMesh or mesh] then
        meshes[mesh] = vehicle:getMeshAlpha(mesh)
        vehicle:setMeshAlpha(0, mesh)
      end
    end
  end
  activeOccupantState = {id = vehicle:getId(), meshes = meshes}
end

local function restoreOccupants()
  local state = activeOccupantState
  if not state then return end
  activeOccupantState = nil
  local vehicle = scenetree.findObjectById(state.id)
  if not vehicle then return end
  for mesh, alpha in pairs(state.meshes) do vehicle:setMeshAlpha(alpha, mesh) end
end

local function restoreCardState(state)
  local object = getCurrentCardObject(state)
  if not object then return true end

  local failures = {}
  local function tryRestore(label, restore)
    local ok, err = pcall(restore)
    if ok then return end
    failures[#failures + 1] = label .. ": " .. tostring(err)
  end

  tryRestore("RenderView mask", function()
    object:unhideInRenderView(reflectionRenderViewMaskBit)
  end)
  tryRestore("transform", function()
    object:setTransform(state.transform)
  end)
  tryRestore("scale", function()
    object:setScale(state.scale)
  end)
  tryRestore("visibility", function()
    object:setHidden(state.hidden)
    object:setRenderEnabled(state.renderEnabled)
  end)
  tryRestore("verification", function()
    if not transformMatches(object, state.transform)
      or not vectorsClose(object:getScale(), state.scale)
      or object:isHidden() ~= state.hidden
      or object:isRenderEnabled() ~= state.renderEnabled
    then
      error("state did not restore exactly")
    end
  end)

  if #failures == 0 then return true end
  log(
    "E",
    logTag,
    "Unable to restore reflection card '" .. state.role .. "': " .. table.concat(failures, "; ")
  )
  return false
end

function M.restoreReflectionCardsAfterTechCapture()
  local success = true
  local failedStates = {}
  for _, role in ipairs(cardRoleOrder) do
    local state = activeTechCardVisibilityStates[role]
    if state then
      local object = getCurrentCardObject(state)
      if not object then
        activeTechCardVisibilityStates[role] = nil
      else
        local ok, err = pcall(function()
          object:setHidden(state.hidden)
          object:setRenderEnabled(state.renderEnabled)
          if object:isHidden() ~= state.hidden
            or object:isRenderEnabled() ~= state.renderEnabled
          then
            error("visibility did not restore exactly")
          end
        end)
        if not ok then
          success = false
          failedStates[role] = state
          log(
            "E",
            logTag,
            "Unable to restore reflection card '" .. role .. "' after Tech capture: " .. tostring(err)
          )
        end
      end
    end
  end
  activeTechCardVisibilityStates = failedStates
  return success
end

function M.hideReflectionCardsForTechCapture()
  if next(activeTechCardVisibilityStates) then
    log("E", logTag, "Nested Tech reflection-card visibility ownership")
    return false
  end

  for _, role in ipairs(cardRoleOrder) do
    local cardState = activeCardStates[role]
    if cardState then
      local object = getCurrentCardObject(cardState)
      if object then
        activeTechCardVisibilityStates[role] = {
          role = role,
          id = cardState.id,
          hidden = object:isHidden(),
          renderEnabled = object:isRenderEnabled()
        }
        local ok, err = pcall(function()
          object:setHidden(true)
          object:setRenderEnabled(false)
          if not object:isHidden() or object:isRenderEnabled() then
            error("visibility did not apply exactly")
          end
        end)
        if not ok then
          log(
            "E",
            logTag,
            "Unable to hide reflection card '" .. role .. "' for Tech capture: " .. tostring(err)
          )
          M.restoreReflectionCardsAfterTechCapture()
          return false
        end
      end
    end
  end
  return true
end

function M.restore()
  setMainViewCardMask(false)
  restoreSsao()
  restoreMarkup()
  restoreOccupants()
  local success = M.restoreReflectionCardsAfterTechCapture()
  local failedCardStates = {}
  for _, role in ipairs(cardRoleOrder) do
    local state = activeCardStates[role]
    if state then
      if restoreCardState(state) then
        activeTechCardVisibilityStates[role] = nil
      else
        success = false
        failedCardStates[role] = state
      end
    end
  end
  activeCardStates = failedCardStates

  local failedStates = {}
  for id, state in pairs(activeLightStates) do
    local ok, err = pcall(function()
      state.object:setTransform(state.transform)
      setLightFields(state.object, state.fields)
      if not transformMatches(state.object, state.transform) then
        error("Light transform did not restore exactly")
      end
    end)
    if not ok then
      success = false
      failedStates[id] = state
      log("E", logTag, "Unable to restore light: " .. tostring(err))
    end
  end
  activeLightStates = failedStates
  return success
end

local function getPointToOobbDistance(point, center, axes, halfExtents)
  local delta = point - center
  local squaredDistance = 0
  for index, halfExtent in ipairs({halfExtents.x, halfExtents.y, halfExtents.z}) do
    local excess = math.max(math.abs(delta:dot(axes[index])) - halfExtent, 0)
    squaredDistance = squaredDistance + excess * excess
  end
  return math.sqrt(squaredDistance)
end

local function flatten(direction)
  local result = vec3(direction.x, direction.y, 0)
  if result:squaredLength() < 0.000001 then return nil end
  result:normalize()
  return result
end

local function rotateAroundUp(direction, angle)
  local cosAngle, sinAngle = math.cos(angle), math.sin(angle)
  return vec3(
    direction.x * cosAngle - direction.y * sinAngle,
    direction.x * sinAngle + direction.y * cosAngle,
    0
  )
end

local function getRearSign(cameraHorizontal, rear)
  return cameraHorizontal:cross(rear).z >= 0 and 1 or -1
end

local function getRigFrame(vehicle, camera)
  local bb = vehicle:getSpawnWorldOOBB()
  local center = vec3(bb:getCenter())
  local probe = vec3(vehicle:getPosition()) + vec3(0, 0, probeHeightOffset)
  local toCamera = vec3(camera.pos) - probe
  local cameraDistance = toCamera:length()
  local cameraHorizontal = flatten(toCamera)
  local lateral = flatten(vec3(bb:getAxis(0)))
  local rear = flatten(-vec3(vehicle:getDirectionVector()))
  if cameraDistance < 0.001 or not cameraHorizontal or not lateral or not rear then
    return nil, "degenerate camera or vehicle orientation"
  end
  local highestZ = -math.huge
  for index = 0, 7 do highestZ = math.max(highestZ, bb:getPoint(index).z) end
  local cameraSide = lateral:dot(cameraHorizontal) >= 0 and lateral or -lateral
  local halfExtents = vec3(bb:getHalfExtents())
  local axes = {vec3(bb:getAxis(0)), vec3(bb:getAxis(1)), vec3(bb:getAxis(2))}
  local function getReach(direction)
    return halfExtents.x * math.abs(direction:dot(axes[1]))
      + halfExtents.y * math.abs(direction:dot(axes[2]))
      + halfExtents.z * math.abs(direction:dot(axes[3]))
  end
  return {
    center = center,
    probe = probe,
    view = toCamera * (1 / cameraDistance),
    cameraDistance = cameraDistance,
    cameraHorizontal = cameraHorizontal,
    cameraSide = cameraSide,
    cameraSideReach = getReach(cameraSide),
    farReach = getReach(-cameraHorizontal),
    rearSign = getRearSign(cameraHorizontal, rear),
    axes = axes,
    halfExtents = halfExtents,
    topZ = highestZ,
    radius = halfExtents:length(),
    probeOffset = (probe - center):length(),
    groundZ = util_screenshotCreator_vehicleSetup.getFloorHeight(bb)
  }
end

-- mirror the view direction about the target body normal: that is the direction the camera sees in it
local function getCardDirection(definition, frame)
  if definition.normal == "camera" then return frame.view end
  local tilt = math.rad(definition.tilt)
  local normal
  if definition.normal == "up" then
    normal = worldUp * math.cos(tilt) + frame.cameraHorizontal * math.sin(tilt)
  else
    normal = frame.cameraSide * math.cos(tilt) + worldUp * math.sin(tilt)
  end
  return (normal * (2 * normal:dot(frame.view)) - frame.view):normalized()
end

-- lightplane emits along +Z, so +Z faces the probe and the long X axis stays horizontal
local function getCardTransform(direction, position, sideReference)
  local toProbe = -direction
  local reference = math.abs(direction.z) > 0.98 and sideReference or worldUp
  local xAxis = reference:cross(toProbe):normalized()
  local transform = MatrixF(true)
  transform:setColumn(0, xAxis)
  transform:setColumn(1, toProbe:cross(xAxis))
  transform:setColumn(2, toProbe)
  transform:setPosition(position)
  return transform
end

local function raiseDirection(direction, frame, degrees)
  local horizontalDirection = flatten(direction) or frame.cameraHorizontal
  local elevation = math.min(math.asin(clamp(direction.z, -1, 1)) + math.rad(degrees), math.rad(89))
  return horizontalDirection * math.cos(elevation) + worldUp * math.sin(elevation)
end

local function getCardPlacement(role, frame)
  local definition = cardRoles[role]
  local direction = getCardDirection(definition, frame)
  local distance = math.max(frame.radius + frame.probeOffset + cardClearance, cardMinDistance)
  if definition.normal == "camera" then
    distance = math.max(distance, frame.cameraDistance + cameraCardBehindDistance)
  end
  local halfWidth = distance * math.tan(math.rad(definition.width) * 0.5)
  local halfHeight = distance * math.tan(math.rad(definition.height) * 0.5)
  local raisedDegrees = 0
  local transform
  repeat
    transform = getCardTransform(direction, frame.probe + direction * distance, frame.cameraSide)
    local lowestZ = transform:getPosition().z - math.abs(transform:getColumn(1).z) * halfHeight
    if lowestZ >= frame.groundZ + floorClearance or direction.z > 0.999 then break end
    direction = raiseDirection(direction, frame, 1)
    raisedDegrees = raisedDegrees + 1
  until raisedDegrees >= 90
  if raisedDegrees > 0 then
    log("D", logTag, string.format("Reflection card '%s' raised %d deg to clear the floor", role, raisedDegrees))
  end
  return transform, halfWidth / lightplaneHalfSize, halfHeight / lightplaneHalfSize
end

local function getHorizonFillPlacement(definition, frame, multiplier)
  local away = -frame.cameraHorizontal
  local keyShadow = (frame.topZ - frame.groundZ) / math.tan(math.rad(lightRoles.key.elevation))
  -- small assets share the sedan's light pool, so the fill starts no closer than it does for a sedan
  local position = frame.center + away * math.max(frame.farReach + keyShadow, definition.minOffset)
  position.z = frame.groundZ + definition.height
  local tilt = math.rad(definition.outerAngle * 0.5)
  local rotation = quatFromDir(away * math.sin(tilt) - worldUp * math.cos(tilt), worldUp)
  local transform = QuatF(rotation.x, rotation.y, rotation.z, rotation.w):getMatrix()
  transform:setPosition(position)
  local axisDistance = definition.height / math.cos(tilt)
  return transform, {
    intensity = definition.lux * multiplier * axisDistance * axisDistance,
    innerAngle = definition.innerAngle,
    outerAngle = definition.outerAngle,
    range = definition.range
  }
end

local function getLightPlacement(role, frame, multiplier)
  local definition = lightRoles[role]
  if definition.aim == "horizon" then return getHorizonFillPlacement(definition, frame, multiplier) end
  local direction = worldUp
  if definition.elevation < 90 then
    local elevation = math.rad(definition.elevation)
    local azimuth = rotateAroundUp(frame.cameraHorizontal, frame.rearSign * math.rad(definition.azimuth))
    direction = azimuth * math.cos(elevation) + worldUp * math.sin(elevation)
  end
  local aimPoint = frame.center
  if definition.aim == "groundCameraSide" then
    aimPoint = frame.center + frame.cameraSide * frame.cameraSideReach
    aimPoint.z = frame.groundZ
  end
  local distance = math.max(frame.radius + lightClearance, frame.radius * lightDistanceScale, lightMinDistance)
  local up = math.abs(direction.z) > 0.99 and frame.cameraSide or worldUp
  local rotation = quatFromDir(-direction, up)
  local transform = QuatF(rotation.x, rotation.y, rotation.z, rotation.w):getMatrix()
  transform:setPosition(aimPoint + direction * distance)
  local poolAngle = 2 * math.deg(math.asin(math.min(1, (frame.radius + lightPoolMargin) / distance)))
  local innerAngle = math.min(poolAngle + 5, 150)
  return transform, {
    intensity = definition.lux * multiplier * distance * distance,
    innerAngle = innerAngle,
    outerAngle = math.min(innerAngle + coneMargin, 170),
    range = distance + frame.radius * 2 + 10
  }
end

function M.selfCheck()
  local frame = {
    view = vec3(0, -1, 0),
    cameraHorizontal = vec3(0, -1, 0),
    cameraSide = vec3(-1, 0, 0)
  }
  assert(vectorsClose(getCardDirection(cardRoles.cameraCard, frame), frame.view))
  assert(vectorsClose(getCardDirection({normal = "up", tilt = 0}, frame), vec3(0, 1, 0)))
  local diagonalView = vec3(-1, -1, 0):normalized()
  local sideFrame = {view = diagonalView, cameraHorizontal = diagonalView, cameraSide = vec3(-1, 0, 0)}
  assert(vectorsClose(getCardDirection({normal = "cameraSide", tilt = 0}, sideFrame), vec3(-1, 1, 0):normalized()))

  local transform = getCardTransform(vec3(0, 1, 0), vec3(0, 10, 0), vec3(-1, 0, 0))
  assert(vectorsClose(transform:getColumn(0), vec3(1, 0, 0)))
  assert(vectorsClose(transform:getColumn(1), vec3(0, 0, 1)))
  assert(vectorsClose(transform:getColumn(2), vec3(0, -1, 0)))
  local topTransform = getCardTransform(vec3(0, 0, 1), vec3(0, 0, 10), vec3(-1, 0, 0))
  assert(vectorsClose(topTransform:getColumn(0), vec3(0, -1, 0)))
  assert(vectorsClose(topTransform:getColumn(2), vec3(0, 0, -1)))

  assert(getRearSign(vec3(1, 0, 0), vec3(0, 1, 0)) == 1)
  assert(vectorsClose(rotateAroundUp(vec3(1, 0, 0), math.pi * 0.5), vec3(0, 1, 0)))
  return true
end

local function isActiveObject(object)
  if object:isHidden() or not object:isRenderEnabled() then return false end
  local enabled = tostring(object:getField("isEnabled", 0) or ""):lower()
  if enabled == "0" or enabled == "false" then return false end
  local intensity = tonumber(object:getField("intensity", 0))
  return intensity == nil or intensity > 0
end

local function getOobbSupport(direction, axes, halfExtents)
  return halfExtents.x * math.abs(direction:dot(axes[1]))
    + halfExtents.y * math.abs(direction:dot(axes[2]))
    + halfExtents.z * math.abs(direction:dot(axes[3]))
end

local function spotlightCanAffectOobb(spotlight, center, halfExtents)
  local range = tonumber(spotlight:getField("range", 0))
  local outerAngle = tonumber(spotlight:getField("outerAngle", 0))
  if not range or range <= 0 or not outerAngle or outerAngle <= 0 or outerAngle >= 180 then
    return false
  end
  local position = spotlight:getPosition()
  local toCenter = center - position
  local distance = toCenter:length()
  local radius = halfExtents:length()
  if distance - radius > range then return false end
  if distance <= radius or distance < 0.000001 then return true end

  local forward = spotlight:getTransform():getColumn(1)
  if forward:squaredLength() < 0.000001 then return false end
  forward:normalize()
  toCenter:normalize()
  local centerAngle = math.acos(clamp(forward:dot(toCenter), -1, 1))
  local angularRadius = math.asin(clamp(radius / distance, 0, 1))
  return centerAngle <= math.rad(outerAngle) * 0.5 + angularRadius
end

local function getSpotlightPlan(spotlight, center, axes, halfExtents)
  local position = spotlight:getPosition()
  if getPointToOobbDistance(position, center, axes, halfExtents) >= spotlightNearDistance
    or not spotlightCanAffectOobb(spotlight, center, halfExtents)
  then
    return nil
  end

  local outward = position - center
  if outward:squaredLength() < 0.000001 then
    outward = -spotlight:getTransform():getColumn(1)
  end
  if outward:squaredLength() < 0.000001 then
    return nil, "SpotLight has no usable outward direction: " .. tostring(spotlight:getID())
  end
  outward:normalize()
  local distance = getOobbSupport(outward, axes, halfExtents) + spotlightClearance
  local range = tonumber(spotlight:getField("range", 0))
  if not range or distance > range then
    log(
      "W",
      logTag,
      string.format(
        "SpotLight %s needs %.2f m to clear the vehicle, range is %.2f m; leaving it in place",
        tostring(spotlight:getID()),
        distance,
        range or 0
      )
    )
    return nil
  end

  local newPosition = center + outward * distance
  local up = vec3(0, 0, 1)
  if math.abs(outward:dot(up)) > 0.99 then up = axes[1] end
  local rotation = quatFromDir(center - newPosition, up)
  local transform = QuatF(rotation.x, rotation.y, rotation.z, rotation.w):getMatrix()
  transform:setPosition(newPosition)
  return {object = spotlight, transform = transform}
end

local function buildSpotlightAdjustmentPlans(vehicle, skippedIds)
  local bb = vehicle:getSpawnWorldOOBB()
  local center = bb:getCenter()
  local axes = {bb:getAxis(0), bb:getAxis(1), bb:getAxis(2)}
  local halfExtents = bb:getHalfExtents()
  local plans = {}

  for _, objectName in ipairs(scenetree.findClassObjects("SpotLight") or {}) do
    local spotlight = scenetree.findObject(objectName)
    if spotlight and not skippedIds[spotlight:getID()] and isActiveObject(spotlight) then
      local plan, planError = getSpotlightPlan(spotlight, center, axes, halfExtents)
      if planError then return nil, planError end
      if plan then plans[#plans + 1] = plan end
    end
  end
  return plans
end

local function applySpotlightAdjustmentPlans(plans)
  for _, plan in ipairs(plans) do rememberLightState(plan.object) end
  local ok, err = xpcall(function()
    for _, plan in ipairs(plans) do
      plan.object:setTransform(plan.transform)
      if not transformMatches(plan.object, plan.transform) then
        error("Unable to apply light transform: " .. tostring(plan.object:getID()))
      end
    end
  end, debug.traceback)
  if ok then return true end
  log("E", logTag, err)
  M.restore()
  return false
end

local function findRoleObjects()
  local cards, lights, markup = {}, {}, {}
  for _, objectName in ipairs(scenetree.getAllObjects() or {}) do
    local object = scenetree.findObject(objectName)
    local hasFields = object and object.getDynDataFieldbyName
    local role = hasFields and object:getDynDataFieldbyName(roleFieldName, 0) or ""
    if hasFields and object:getDynDataFieldbyName(markupFieldName, 0) == markupLayerName then
      markup[#markup + 1] = object
    end
    local isCard = cardRoles[role] ~= nil
    if isCard or lightRoles[role] then
      local targets = isCard and cards or lights
      local valid
      if isCard then
        valid = object:getClassName() == "TSStatic" and isLightplane(object)
      else
        valid = object:getClassName() == "SpotLight"
      end
      if targets[role] then
        log("W", logTag, string.format("Role '%s' is already taken, ignoring %s", role, objectName))
      elseif not valid then
        log("W", logTag, string.format("Role '%s' does not fit %s (%s)", role, objectName, object:getClassName()))
      else
        targets[role] = object
      end
    end
  end
  return cards, lights, markup
end

function M.getMarkupCount()
  local _, _, markup = findRoleObjects()
  return #markup
end

function M.clearMarkupTags()
  local _, _, markup = findRoleObjects()
  for _, object in ipairs(markup) do object:setDynDataFieldbyName(markupFieldName, 0, "") end
  return #markup
end

local function applyRoleLight(role, light, frame, roleSettings)
  local state = rememberLightState(light)
  local transform, fields = getLightPlacement(role, frame, roleSettings.intensity)
  -- horizon fill relies on its exact cone and range to stay off the vehicle
  if lightRoles[role].aim ~= "horizon" then
    fields.range = math.max(tonumber(state.fields.range) or 0, fields.range)
    -- the shadow map spans the outer cone, so keeping the wide level angle keeps shadows and the light pool soft
    fields.outerAngle = math.max(tonumber(state.fields.outerAngle) or 0, fields.outerAngle)
  end
  fields.castShadows = roleSettings.shadows and "1" or "0"
  local ok, err = xpcall(function()
    light:setTransform(transform)
    setLightFields(light, fields)
    if not transformMatches(light, transform) then
      error("transform did not apply exactly")
    end
  end, debug.traceback)
  if ok then return true end
  log("E", logTag, "Unable to place light role '" .. role .. "': " .. tostring(err))
  return false
end

-- same falloff as the clustered spot shader: windowed inverse square times the linear cone ramp, no shadows
local function getSpotIlluminance(light, point, normal)
  local toPoint = point - vec3(light:getPosition())
  local distanceSqr = toPoint:squaredLength()
  local range = tonumber(light:getField("range", 0)) or 0
  if distanceSqr < 0.000001 or distanceSqr >= range * range then return 0 end
  local direction = toPoint / math.sqrt(distanceSqr)
  local cosOuter = math.cos(math.rad((tonumber(light:getField("outerAngle", 0)) or 0) * 0.5))
  local cosInner = math.cos(math.rad((tonumber(light:getField("innerAngle", 0)) or 0) * 0.5))
  local forward = vec3(light:getTransform():getColumn(1)):normalized()
  local cone = (forward:dot(direction) - cosOuter) / math.max(cosInner - cosOuter, 0.0001)
  if cone <= 0 then return 0 end
  local window = math.max(0, 1 - (distanceSqr / (range * range)) ^ 2) ^ 2
  local intensity = tonumber(light:getField("intensity", 0)) or 0
  return intensity * math.min(cone, 1) * window * math.max(0, -normal:dot(direction)) / distanceSqr
end

-- mean illuminance over the OOBB faces the camera sees, weighted by their projected area
local function getVisibleFaceIlluminance(lights, frame, cameraPosition)
  local halfExtents = {frame.halfExtents.x, frame.halfExtents.y, frame.halfExtents.z}
  local sampleCount = #exposureSampleSteps * #exposureSampleSteps
  local weightedSum, weightSum = 0, 0
  for index = 1, 3 do
    for _, sign in ipairs({-1, 1}) do
      local normal = frame.axes[index] * sign
      local faceCenter = frame.center + normal * halfExtents[index]
      local facing = normal:dot((cameraPosition - faceCenter):normalized())
      if facing > 0 then
        local uIndex, vIndex = index % 3 + 1, (index + 1) % 3 + 1
        local sum = 0
        for _, u in ipairs(exposureSampleSteps) do
          for _, v in ipairs(exposureSampleSteps) do
            local point = faceCenter
              + frame.axes[uIndex] * (u * halfExtents[uIndex])
              + frame.axes[vIndex] * (v * halfExtents[vIndex])
            for _, light in ipairs(lights) do sum = sum + getSpotIlluminance(light, point, normal) end
          end
        end
        local weight = facing * halfExtents[uIndex] * halfExtents[vIndex]
        weightedSum = weightedSum + weight * sum / sampleCount
        weightSum = weightSum + weight
      end
    end
  end
  return weightSum > 0 and weightedSum / weightSum or 0
end

local function applyExposureCorrection(lights, frame, camera)
  local scaled, fixed = {}, {}
  local scaledIds = {}
  for role, light in pairs(lights) do
    if exposureRoles[role] then
      scaled[#scaled + 1] = light
      scaledIds[light:getID()] = true
    end
  end
  for _, objectName in ipairs(scenetree.findClassObjects("SpotLight") or {}) do
    local light = scenetree.findObject(objectName)
    if light and not scaledIds[light:getID()] and isActiveObject(light) then fixed[#fixed + 1] = light end
  end

  local cameraPosition = vec3(camera.pos)
  local scaledLux = getVisibleFaceIlluminance(scaled, frame, cameraPosition)
  local fixedLux = getVisibleFaceIlluminance(fixed, frame, cameraPosition)
  if scaledLux <= 0 then return end
  local gain = clamp((exposureTarget - fixedLux) / scaledLux, exposureMinGain, exposureMaxGain)
  for _, light in ipairs(scaled) do
    setLightFields(light, {intensity = (tonumber(light:getField("intensity", 0)) or 0) * gain})
  end
  log("I", logTag, string.format(
    "Exposure correction: visible faces %.0f lx -> %.0f lx (gain %.2f, radius %.2f m)",
    scaledLux + fixedLux, scaledLux * gain + fixedLux, gain, frame.radius
  ))
end

local function rememberCardState(role, object)
  if activeCardStates[role] then return activeCardStates[role] end
  local state = {
    role = role,
    id = object:getID(),
    transform = object:getTransform() * MatrixF(true),
    scale = vec3(object:getScale()),
    hidden = object:isHidden(),
    renderEnabled = object:isRenderEnabled()
  }
  activeCardStates[role] = state
  return state
end

local function prepareCard(role, object, frame)
  local state
  local snapshotOk, snapshotError = pcall(function()
    state = rememberCardState(role, object)
  end)
  if not snapshotOk then
    log("E", logTag, "Unable to snapshot reflection card '" .. role .. "': " .. tostring(snapshotError))
    return true
  end

  local transform, scale
  if frame then
    local scaleX, scaleY
    transform, scaleX, scaleY = getCardPlacement(role, frame)
    scale = vec3(scaleX, scaleY, state.scale.z)
  end

  local ok, err = xpcall(function()
    object:hideInRenderView(reflectionRenderViewMaskBit)
    if transform then
      object:setTransform(transform)
      object:setScale(scale)
    end
    object:setHidden(false)
    object:setRenderEnabled(true)
    if object:isHidden() or not object:isRenderEnabled()
      or not vectorsClose(object:getScale(), scale or state.scale)
      or (transform and not transformMatches(object, transform))
    then
      error("applied state did not verify exactly")
    end
  end, debug.traceback)
  if ok then return true end

  log("E", logTag, "Unable to prepare reflection card '" .. role .. "': " .. tostring(err))
  local restored = restoreCardState(state)
  if restored then activeCardStates[role] = nil end
  return restored
end

function M.adjust(vehicle, camera)
  if not selfChecked then
    M.selfCheck()
    selfChecked = true
  end
  if not M.restore() then return false end
  if not vehicle or type(camera) ~= "table" or not camera.pos or not camera.rot then
    log("E", logTag, "Lighting adjustment requires a vehicle and resolved camera")
    return false
  end

  local rig = util_screenshotCreator_settings.getLightingRig()
  local cards, lights, markup = findRoleObjects()
  local frame
  if rig.enabled then
    local frameError
    frame, frameError = getRigFrame(vehicle, camera)
    if not frame then
      log("E", logTag, "Unable to build the lighting rig: " .. tostring(frameError))
      return false
    end
  end

  local rigLightIds = {}
  if frame then
    for _, light in pairs(lights) do rigLightIds[light:getID()] = true end
  end
  local plans, planError = buildSpotlightAdjustmentPlans(vehicle, rigLightIds)
  if not plans then
    log("E", logTag, tostring(planError))
    return false
  end
  if not applySpotlightAdjustmentPlans(plans) then return false end

  if frame then
    for _, role in ipairs(lightRoleOrder) do
      local light = lights[role]
      if light and not applyRoleLight(role, light, frame, rig.roles[role]) then
        M.restore()
        return false
      end
    end
    if rig.exposureCorrection then applyExposureCorrection(lights, frame, camera) end
  end
  for _, role in ipairs(cardRoleOrder) do
    local card = cards[role]
    if card and not prepareCard(role, card, frame) then
      M.restore()
      return false
    end
  end
  applySsaoMode(rig.ssaoMode)
  applyMarkupVisibility(markup, rig.parkingMarkup == true)
  hideOccupants(vehicle)
  setMainViewCardMask(true)
  return true
end

M.onExtensionUnloaded = M.restore
M.onClientEndMission = M.restore
M.onExit = M.restore

return M
