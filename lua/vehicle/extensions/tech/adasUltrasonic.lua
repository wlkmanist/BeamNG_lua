-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local lastBrake = 0
local fullStop = false

local parkAssist
local blindSpots
local crawl

local function setup(enableParkAssist, enableBlindSpots, hasCrawl)
  parkAssist = enableParkAssist
  blindSpots = enableBlindSpots
  crawl = hasCrawl
end

local function initAdasUpdate()
  if electrics.values.wheelspeed < 0.02 then
    extensions.tech_adasInput.apply(0, 'brake', 'safe')
    extensions.tech_adasInput.apply(100, 'throttle', 'safe')
    lastBrake = 0
    return
  elseif parkAssist then
    if electrics.values.wheelspeed <= 3.5 then
      electrics.values.parkassist = 1
      obj:queueGameEngineLua("extensions.tech_adasUltrasonic.runUpdate(1)")
      return
    else
      electrics.values.parkassist = 0
      extensions.tech_adasInput.apply(0, 'brake', 'safe')
      extensions.tech_adasInput.apply(100, 'throttle', 'safe')
    end
  end
  if blindSpots then
    obj:queueGameEngineLua("extensions.tech_adasUltrasonic.runUpdate(0)")
  end
end

local function applyBrakes(dist)
  local brake
  if dist < (fullStop and 0.05 or 0.15) then
    fullStop = true
    brake = 1
    controller.mainController.shiftToGearIndex(0)
  else
    brake = math.min(1, math.log(1 + electrics.values.wheelspeed) / ((crawl and 4 or 6) * dist))
    brake = (brake + lastBrake) / 2
    fullStop = false
  end

  if brake > 0.01 then
    extensions.tech_adasInput.apply(brake, 'brake', 'safe')
    extensions.tech_adasInput.apply(0, 'throttle', 'safe')
    lastBrake = brake
  else
    extensions.tech_adasInput.apply(0, 'brake', 'safe')
    extensions.tech_adasInput.apply(1, 'throttle', 'safe')
    lastBrake = 0
  end
end

-- Public interfacce
M.setup          = setup
M.initAdasUpdate = initAdasUpdate
M.applyBrakes    = applyBrakes

return M