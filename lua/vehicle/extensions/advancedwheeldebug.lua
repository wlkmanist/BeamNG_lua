-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local acos = math.acos
local deg = math.deg

local debugUsers = {}
local isDebugEnabled = false

local function onInit()
  debugUsers = {}
  isDebugEnabled = false
end

local function registerDebugUser(user, value)
  debugUsers[user] = value

  isDebugEnabled = false
  for _,v in pairs(debugUsers) do
    isDebugEnabled = isDebugEnabled or v
  end
end

local function updateGFX(dt)
  if not isDebugEnabled then
    return
  end

  local vectorForward = obj:getDirectionVector()
  local vectorUp = obj:getDirectionVectorUp()
  local vectorRight = vectorForward:cross(vectorUp)

  local data = {}
  for _,wd in pairs(v.data.wheels) do
    local name = wd.name
    local wheelData = {name = name}
    if wd.steerAxisUp and wd.steerAxisDown then
      wheelData.caster = deg(acos(obj:nodeVecPlanarCos(wd.steerAxisUp, wd.steerAxisDown, vectorUp, vectorForward)))
      wheelData.sai = deg(acos(obj:nodeVecPlanarCos(wd.steerAxisUp, wd.steerAxisDown, vectorUp, vectorRight)))
    end
    --local camberSign = obj:nodeVecCos(wd.node2, wd.node2, vectorForward) --unused
    wheelData.camber = (90 - deg(acos(obj:nodeVecPlanarCos(wd.node2, wd.node1, vectorUp, vectorRight))))
    local toeSign = obj:nodeVecCos(wd.node1, wd.node2, vectorForward)
    wheelData.toe = deg(acos(obj:nodeVecPlanarCos(wd.node1, wd.node2, vectorRight, vectorForward)))
    if wheelData.toe > 90 then
      wheelData.toe = (180 - wheelData.toe) * sign(toeSign)
    else
      wheelData.toe = wheelData.toe * sign(toeSign)
    end

    -- failsafes for NaN below, broke UI before ...
    if isnan(wheelData.toe) or isinf(wheelData.toe) then
      wheelData.toe = 0
    end
    if isnan(wheelData.camber) or isinf(wheelData.camber) then
      wheelData.camber = 0
    end

    local hasPressure = wd.pressureGroup and v.data.pressureGroups and v.data.pressureGroups[wd.pressureGroup]
    wheelData.pressure = hasPressure and obj:getGroupPressure(v.data.pressureGroups[wd.pressureGroup]) * 0.000145038 or 0

    table.insert(data, wheelData)
  end

  if not playerInfo.firstPlayerSeated then return end
  gui.send('advancedWheelDebugData', data)
end

-- public interface
M.onInit    = onInit
M.updateGFX = updateGFX
M.registerDebugUser = registerDebugUser

return M