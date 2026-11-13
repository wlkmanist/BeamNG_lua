-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local layers = require("ui/apps/minimap/layers")

-- Vehicle drawing state variables
local lastPos, lastPos2, pos, fwd = vec3(), vec3(), vec3(), vec3()
local lastDtSim, lastVel = 0, 0
local vehicleData, vel
local hasLastPosition = false
local localFwd = vec3(0,1,0)
local velSmoother = newTemporalSmoothing(0.25,0.5, nil, 1)
local walkSmoother = newTemporalSmoothing(2,1, nil, 1)
local scaleSetting = 0.5 -- px/m

local tmp1, tmp2, tmp3 = vec3(), vec3(), vec3()
local adjustedCamPos, freeCamLookWithoutZ = vec3(), vec3()

-- State variables that need to be set by the main minimap
local width, height, centerX, centerY
local camPos, camRot, camRotInverse, scale, scaleInverse
local td, debugSettings, cameraLook, currentStyleColorSet
local dpi = 1
local worldToMapXX, worldToMapXY, worldToMapYX, worldToMapYY = 0, 0, 0, 0
local worldToMapXOffset, worldToMapYOffset = 0, 0

-- Setter function to update state from main minimap
M.setMinimapState = function(w, h, cx, cy, cp, cr, cri, s, si, textureDraw, debugSettingsObj, cameraLookObj, dpiValue)
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
  debugSettings = debugSettingsObj
  cameraLook = cameraLookObj
  dpi = dpiValue or 1
  dpi = dpi * (globalDpi or 1)
  currentStyleColorSet = ui_apps_minimap_utils.getCurrentStyleColors() or ui_apps_minimap_utils.colors
  worldToMapXX, worldToMapXY, worldToMapYX, worldToMapYY, worldToMapXOffset, worldToMapYOffset =
    ui_apps_minimap_utils.getWorldToMapTransform()
end

local function drawVehicle(pos, fwd, color, size, asCircle, layer)
  td:vehicleMarker(pos.x, pos.y, fwd.x, fwd.y, color, currentStyleColorSet.navBg, size, not not asCircle, scale, dpi, worldToMapXX, worldToMapXY, worldToMapYX, worldToMapYY, worldToMapXOffset, worldToMapYOffset, layer or layers.VEHICLES_OTHER)
end

local rot = quat()
local function drawPlayer(dtReal, dtSim)
  local isWalking = gameplay_walk and gameplay_walk.isWalking()
  if isWalking then
    pos:set(gameplay_walk.getPosXYZ())
    rot:set(gameplay_walk.getRotXYZW())
    fwd:setRotate(rot, localFwd)
    fwd.z = 0
    fwd:normalize()
  else
    local vehId = be:getPlayerVehicleID(0)
    if not vehId then return end
    vehicleData = map.objects[vehId] or nil
    if not vehicleData then return end
    pos:set(vehicleData.pos)
    fwd:set(vehicleData.dirVec.x,vehicleData.dirVec.y,0)
    fwd:normalize()
  end

  vel = (hasLastPosition and lastDtSim > 0.0001) and (lastPos:distance(lastPos2) / lastDtSim) or lastVel
  local dynamicScale = clamp(velSmoother:get(vel > 10 and 3.0 or 1, dtReal), 1, 1.75)
  local walkScale = walkSmoother:get(isWalking and 0 or 1, dtReal)
  dynamicScale = smoothstep((dynamicScale-1) / 0.75)*0.75 + 1
  local adjustedScale = dynamicScale * scaleSetting * (0.7*smoothstep(walkScale)+0.3)
  local sizeFactor = math.min((math.min(width, height) / 400), 1)

  adjustedScale = adjustedScale / sizeFactor

  if debugSettings.drawPlayer then
    drawVehicle(pos, fwd, currentStyleColorSet.clrFocus, 1, isWalking, layers.VEHICLE_PLAYER)
  end
  if commands.isFreeCamera() then
    --drawVehicle(camPos, cameraLook, clrOrange, 1, true, layers.VEHICLE_PLAYER)
    tmp1:set(cameraLook)

    -- Apply lookahead offset to camera position for free camera drawing
    adjustedCamPos:set(camPos)
    if debugSettings.lookaheadEnabled then
      local debugSettingsData = ui_apps_minimap_minimap.getDebugSettingsData()
      local lookaheadValue = debugSettingsData.lookaheadValue[debugSettings.lookaheadValue].value
      freeCamLookWithoutZ:set(cameraLook.x, cameraLook.y, 0)
      freeCamLookWithoutZ:normalize()
      freeCamLookWithoutZ:setScaled(lookaheadValue * scale * height/2)
      adjustedCamPos:setSub(freeCamLookWithoutZ)
    end

    tmp1:setScaled(scale * 10 * dpi)
    tmp2:set(adjustedCamPos)
    tmp2:setAdd(tmp1)
    tmp1:setScaled(1.25)
    tmp3:set(adjustedCamPos)
    tmp3:setSub(tmp1)
    tmp1:set(adjustedCamPos)
    ui_apps_minimap_utils.worldToMapXYZ(tmp1,tmp1)
    ui_apps_minimap_utils.worldToMapXYZ(tmp2,tmp2)
    ui_apps_minimap_utils.worldToMapXYZ(tmp3,tmp3)

    local strokeWidth = math.max(1, math.floor(2 * dpi))
    td:line(tmp3.x, tmp3.y, tmp2.x, tmp2.y, 0, 4*dpi, strokeWidth, strokeWidth, currentStyleColorSet.navBg, currentStyleColorSet.navBg, currentStyleColorSet.navBg, currentStyleColorSet.navBg, 0, layers.VEHICLE_PLAYER)
    td:line(tmp1.x, tmp1.y, tmp3.x, tmp3.y, 6*dpi, 6*dpi, strokeWidth, strokeWidth, currentStyleColorSet.navBg, currentStyleColorSet.navBg, currentStyleColorSet.navBg, currentStyleColorSet.navBg, 0, layers.VEHICLE_PLAYER)

    td:line(tmp3.x, tmp3.y, tmp2.x, tmp2.y, 0, 4*dpi, 0, 0, currentStyleColorSet.clrFocus, currentStyleColorSet.clrFocus, currentStyleColorSet.clrFocus, currentStyleColorSet.clrFocus, 0, layers.VEHICLE_PLAYER)
    td:line(tmp1.x, tmp1.y, tmp3.x, tmp3.y, 6*dpi, 6*dpi, 0, 0, currentStyleColorSet.clrFocus, currentStyleColorSet.clrFocus, currentStyleColorSet.clrFocus, currentStyleColorSet.clrFocus, 0, layers.VEHICLE_PLAYER)
  end

  -- nightmare to fix dtSim not being in sync with the map data
  if hasLastPosition then
    lastPos2:set(lastPos)
    lastPos:set(pos)
  else
    lastPos:set(pos)
    lastPos2:set(pos)
    hasLastPosition = true
  end
  lastDtSim, lastVel = dtSim, vel
  return adjustedScale
end

local vehIteratorCtx = {}
local ignoredTypes = {
  ['Prop'] = true,
  ['Unknown'] = true,
  ['Utility'] = true,
  ['PropTraffic'] = true,
  ['Traffic'] = true,
}
local ignoredModels = {}
local function isIgnoredModel(jbeam)
  if not jbeam then return false end
  local ignored = ignoredModels[jbeam]
  if ignored == nil then
    local model = core_vehicles.getModel(jbeam)
    ignored = not not (model and model.model and model.model.Type and ignoredTypes[model.model.Type])
    ignoredModels[jbeam] = ignored
  end
  return ignored
end

local function drawOtherVehicles(dtReal, dtSim)
  local playerVehId = be:getPlayerVehicleID(0)
  local traffic = debugSettings.drawTrafficVehicles and gameplay_traffic.getTrafficData() or nil
  local parking = debugSettings.drawParkedVehicles and gameplay_parking.getParkedCarsData() or nil
  local policeCars = gameplay_police.getPoliceVehicles()
  local walk = gameplay_walk
  local cullRadius = math.sqrt(width * width + height * height) * scale * 0.5 + 16 * scale * dpi
  local policePulseTime = os.clock() * 5

  for otherVId, otherVeh in activeVehiclesIterator(vehIteratorCtx) do
    if otherVId ~= playerVehId then
      pos:set(otherVeh:getPositionXYZ())
      local isCulled = math.abs(pos.x - camPos.x) > cullRadius or math.abs(pos.y - camPos.y) > cullRadius
      if isCulled then
        goto continue
      end

      local policeData = policeCars[otherVId]
      local policeRole = policeData and policeData.role
      local isActivePoliceCar = false
      if policeRole and policeRole.targetId == playerVehId and policeRole.targetPursuitMode > 0 then
        isActivePoliceCar = true
      end

      local draw = (parking and parking[otherVId])
        or (debugSettings.drawActivePoliceVehicles and isActivePoliceCar)
        or (traffic and traffic[otherVId])
      local filterModel = not draw

      if filterModel and isIgnoredModel(otherVeh.jbeam) then
        goto continue
      end

      local canUse = not walk or not walk.isVehicleBlacklisted(otherVId)
      if not draw then
        if not debugSettings.drawUnusableVehicles and not canUse then
          goto continue
        end
        if not debugSettings.drawOtherVehicles and not canUse then
          goto continue
        end
        draw = true
      end

      fwd:set(otherVeh:getDirectionVectorXYZ())
      fwd.z = 0
      fwd:normalize()

      local vehColor = currentStyleColorSet.clrFocusMuted
      if not canUse then
        vehColor = currentStyleColorSet.grayMuted
      end

      local vehLayer = layers.VEHICLES_OTHER
      if policeData then
        local policePulse = policePulseTime + otherVId * 0.01
        vehColor = color(math.sin(policePulse)*128+128, 0, math.sin(policePulse+math.pi)*128+128, 255)
        vehLayer = layers.VEHICLES_POLICE
      elseif canUse then
        vehLayer = layers.VEHICLES_USABLE
      end

      drawVehicle(pos, fwd, vehColor, canUse and 0.8 or (policeData and 0.8 or 0.5), otherVeh.jbeam == "unicycle", vehLayer)
      ::continue::
    end
  end
end

-- Expose the functions
M.drawPlayer = drawPlayer
M.drawOtherVehicles = drawOtherVehicles

return M