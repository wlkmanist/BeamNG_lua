-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local min, max, abs, clockhp = math.min, math.max, math.abs, os.clockhp
local M = {}

M.enableFFB = true
M.wheelFFBForceCoef = 200 -- regular force coef (at speed)
M.wheelFFBForceCoefLowSpeed = M.wheelFFBForceCoef -- force coef used at parking speeds
M.wheelFFBForceCoefCurrent = M.wheelFFBForceCoefLowSpeed -- updated over time depending on speed (start at parking speed) and AI driver
M.wheelPowerSteeringCoef = 1
M.wheelFFBForceLimit = 10 -- The FFB steady force limits (in Newton)
local wheelFFBSmoothing, wheelFFBSmoothing2 = 50, 50000
local wheelFFBSmoothing2automatic = true
M.GforceCoef = 0
local GforceVelCoef = 0

M.hydros = {}
local hydroCount = 0
M.forceAtWheel = 0
local prevForceQuantum = 0
M.forceAtDriver = 0
M.curForceLimit = 0

local inputFlex = {}

local vehicleFFBForceCoef = 1.2
local responseCurve = 0
local responseCorrected = false
-- local FFBsmooth = newExponentialSmoothing(wheelFFBSmoothing)
local FFBsmooth = newExponentialSmoothingT(wheelFFBSmoothing, wheelFFBSmoothing2)
local FFBHydros = {}
local FFBRest = {}
local FFBRestCount = 0
local FFBHydrosExist = false
local FFBID    = -1 -- >=0 are valid IDs
local curForceLimitSmoother = newTemporalSmoothingNonLinear(10) -- prevent spikes when resetting vehicle (and ideally also when window focus is lost/gained)
local FFBperiod = 0 -- how small period the steering wheel drivers can cope with, before they crash and burn
local nextDriverUpdate = 0 -- last time we sent an update to the drivers
local FFmax = 10
local softlockForceCoef = 1
local softlockDegrees = 40 -- in these last degrees of steering range, we apply forces to keep the USB steering wheel within the vlua steering lock. e.g. if driving a 360deg Bolide with a 900deg logitech wheel, then from 320 to 360deg (and beyond) the logitech will start pushing back
local softlockThreshold = nil
local softlockDamping = 1
local invFFstep = 65536 / FFmax
local ffbSpeedFast = 5 / 3.6
local dtInternal = 1
local m1, delta1m1, delta1m1m2
local y1,y2,y2R = 0,0,0
local prevdt = 1
local steeringHydro = nil
local physicsDt = physicsDt
local prevWheelPos = 0

local function toInputSpace(h, state)
  return (state - h.center) * (state > h.center and h.invMultOut or h.invMultIn)
end

-- process the response correction curve that getDriverForce will use. happens only once
local function processResponseCurve(rCurve)
  if tableSize(rCurve) < 2 then
    log("W", "", "FFB response functionality disabled due to invalid curve table size: "..dumps(rCurve))
    responseCorrected = false
    return
  end

  -- find table range (for later normalization)
  local maxx = 0
  local maxy = 0
  for _,p in ipairs(rCurve) do
    if p[1] > maxx then maxx = p[1] end
    if p[2] > maxy then maxy = p[2] end
  end
  if maxx == 0 or maxy == 0 then
    log("W", "", "FFB response functionality disabled due to flat curve: "..dumps(rCurve))
    responseCorrected = false
    return
  end

  -- normalize table, from 0..N to 0..1
  table.insert(rCurve, 1, {0,0})
  for i, p in pairs(rCurve) do
    p[1] = p[1]/maxx
    p[2] = p[2]/maxy
  end

  -- convert into strictly increasing values. this also removes initial force deadzone, and rectifies any ending downslope
  local result = { {1,1} }
  for i=tableSize(rCurve),1,-1 do
    if rCurve[i][1] < result[1][1] and rCurve[i][2] < result[1][2] then
      table.insert(result, 1, rCurve[i])
    end
  end

  if tableSize(result) < 2 then
    log("W", "", "FFB response functionality disabled due to invalid normalized curve: "..dumps(result))
    responseCorrected = false
    return
  end
  return result
end

-- use response correction table to figure out what value to feed the drivers with
local function getDriverForce(force)
  local normForce = math.abs(force) / FFmax
  local prev
  local nxt
  -- find current section (previous and next datapoint) in response curve
  for i = 1, #responseCurve do
    nxt = responseCurve[i]
    if nxt[2] > normForce then break end
    if nxt[2] == 1 then break end
    prev = nxt
  end
  -- map from desired wheel force, to necessary driver force, after taking into account hardware response
  local prev2 = prev and prev[2] or 0
  local normResult = prev[1] + (normForce - prev2) * (nxt[1] - (prev and prev[1] or 0)) / (nxt[2] - prev2)
  return sign(force) * normResult * FFmax
end

local function FFBcalc(wheelDispl, wheelPos)
  M.forceAtWheel = M.wheelFFBForceCoefCurrent * vehicleFFBForceCoef * wheelDispl * M.wheelPowerSteeringCoef

  -- TODO: why check for ffb and controller presence (steering wheel hardware) this late, instead of at the beginning of function?
  -- TODO: or better yet, remove this check, and move FFBcalc() call to inside the hydros calculation in update(dtSim) function?
  if FFBID >= 0 and playerInfo.anyPlayerSeated then
    -- compute the force that should be output by (and measured at) the steering wheel hardware

    -- filter 'huge' spikes from going into the smoother; otherwise, it'll take a while to come back from that far away (in later calls to FFBsmooth:get)
    -- we use a multiplier value of 10; this way the return value of :get() won't be overly smoothed when driving on the limit, i.e. approaching the limit of ffb, i.e. near curForceLimit and towards it
    -- TODO: instead, maybe we can re-set the smoother when we've gone over the limit and use getUncapped? (just like the fix for lag in skidding sound smoothers)
    -- reminder: FFBsmooth must run at a constant rate, such as 2KHz (replace with a temporal smoother otherwise)
    local limit = 10 * M.curForceLimit
    M.forceAtWheel = FFBsmooth:getWindow(max(min(M.forceAtWheel, limit), -limit), wheelFFBSmoothing, wheelFFBSmoothing2) - GforceVelCoef * sensors.gx * M.GforceCoef

    -- drivers will struggle if sending too many updates per wall clock second, so we throttle them here (according to FFBperiod)
    local now = clockhp() -- important, this must be wall clock time, not sim time (steering wheel drivers don't care about sim time)
    -- TODO: FFBperiod is literally the avg time it takes for udpates to run when drivers are overloaded, which we assume is close to the max rate the drivers can handle. is that a correct assumption in all cases?
    -- TODO: also, should we add some wiggle room here? maybe use FFBperiod*1.5 or something like that instead?
    if now > nextDriverUpdate then

      -- limit how much torque is output at the wheel (following the binding configuration of curForceLimit)
      local forceAtWheel = sign(M.forceAtWheel) * min(abs(M.forceAtWheel), M.curForceLimit)

      -- figure out the fake number that the drivers want to hear, in order to really output the desired torque at the wheel
      local newForceAtDriver = responseCorrected and getDriverForce(forceAtWheel) or forceAtWheel

      -- progressively apply softlock during the last few degrees of steering lock
      softlockThreshold = softlockThreshold or 0.5*clamp(softlockDegrees / v.data.input.steeringWheelLock, 1e-10, 1)
      local absWheelPos = abs(wheelPos)
      local lockForce = clamp(1 + (absWheelPos - 1) / softlockThreshold, -1, 1)
      if lockForce >= 0 then
        lockForce = lockForce - min(lockForce, square(softlockDamping * max(0, abs(prevWheelPos) - absWheelPos) / physicsDt))
      end
      lockForce = M.curForceLimit * lockForce
      --lockForce = lockForce
      if wheelPos >= 0 then
        lockForce = max(newForceAtDriver, lockForce)
      else
        lockForce = min(newForceAtDriver, -lockForce)
      end

      newForceAtDriver = (1 - softlockForceCoef) * newForceAtDriver + softlockForceCoef * lockForce
      newForceAtDriver = M.enableFFB and newForceAtDriver or 0

      -- send force only if the driver will see any difference (i.e. skip when still in the same driver ffb quantum step as last time)
      local newForceQuantum = sign(newForceAtDriver) * math.floor(abs(newForceAtDriver * invFFstep))
      if newForceQuantum ~= prevForceQuantum then
        -- send update to driver
        obj:sendForceFeedback(FFBID, newForceAtDriver)
        nextDriverUpdate = now + FFBperiod

        -- remember data for future calculations
        M.forceAtWheel = forceAtWheel
        prevForceQuantum = newForceQuantum
        M.forceAtDriver = newForceAtDriver
      end
    end
  end
  prevWheelPos = wheelPos
end

local function updateGFX(dt) -- dt in seconds
  local invPhysSteps = physicsDt / dt

  for k, f in pairs(inputFlex) do
    local eval = electrics.values[k]
    if eval then
      local offset = f.offset
      if f.offsetDiff ~= 0 and not(k == "steering_input" and FFBID >= 0 and playerInfo.anyPlayerSeated) then
        offset = offset + signApply(f.offsetDiff, min(abs(f.offsetDiff), f.maxRate * dt))
        offset = min(max(offset + eval, f.inLimit), f.outLimit) - eval
      else
        offset = signApply(offset, max(0, abs(offset) - f.minRate * dt))
      end
      f.offsetDiff = 0
      f.offset = offset
      f.value = eval + offset
    end
  end

  -- update the source command value
  for i = 1, hydroCount do
    local h = M.hydros[i]
    h.prevstate = h.state
    h.cmd = min(max(inputFlex[h.inputSource].value or 0, h.inputInLimit), h.inputOutLimit) * h.inputFactor

    -- flex input
    if h.forceLimit then
      local stress = obj:getBeamStress(h.bcid) * h.inputFactor
      local absStress = abs(stress)
      if absStress > h.forceLimit then
        inputFlex[h.inputSource].offsetDiff = inputFlex[h.inputSource].offsetDiff + signApply(stress, absStress - h.forceLimit) / (v.data.beams[h.bcid].beamSpring * min(h.multOut, h.multIn))
      end
    end

    if h.cmd == h.inputCenter and h.analogue == false and h.autoCenterRate then
      -- set autocenter rate
      h._inrate, h._outrate = h.autoCenterRate * physicsDt, h.autoCenterRate * physicsDt
    else
      h._inrate, h._outrate = h.inRate * physicsDt, h.outRate * physicsDt
    end

    if h.cmd >= h.inputCenter then
      h.cmd = h.cOut + h.cmd * h.multOut
    else
      h.cmd = h.cIn + h.cmd * h.multIn
    end

    h.smoothrate = abs(h.state - h.cmd) * invPhysSteps
  end

  if FFBHydrosExist then
    local FFBhcount = 0
    local hydroPos = 0
    local simWheelPos = 0
    for i = 1, #FFBHydros do
      local h = FFBHydros[i]
      h._inrate, h._outrate = h.inRate * physicsDt, h.outRate * physicsDt
      local hbcid = h.bcid
      if not h.fIsBroken(obj, hbcid) then
        FFBhcount = FFBhcount + 1
        hydroPos = hydroPos + toInputSpace(h, h.fgetDisplacement(obj, hbcid) * h.invFFBHydroRefL)
        simWheelPos = simWheelPos + toInputSpace(h, h.state)
      end
    end

    prevForceQuantum = math.huge
    local invDt = 1 / (dt + 1e-30)
    dtInternal = 0
    local y0 = y1
    local invFFBCount = 1 / max(1, FFBhcount)
    y1, hydroPos = simWheelPos * invFFBCount, hydroPos * invFFBCount

    local prevy2R, prevPredy2 = y2R, y2
    y2 = electrics.values.steering_input or 0  -- current pos
    y2R = y2

    local predDelta = dt * (y2R - prevy2R) / (prevdt + 1e-10)
    if (hydroPos - y2R) * predDelta >= 0 then
      y2 = y2R + min(max((y2R - prevy2R) / (prevPredy2 - prevy2R), 0), 1) * predDelta
    end

    local wheelvel = (y2 - prevPredy2) * invDt
    local delta2 = wheelvel
    local delta0 = (y1-y0) / (prevdt + 1e-30)
    local delta1 = (y2-y1) * invDt
    m1 = (sign(delta0)+sign(delta1)) * min(abs(delta0),abs(delta1), 0.5*abs((dt*delta0 + prevdt*delta1) / (prevdt + dt + 1e-30)))
    local m2 = (sign(delta1)+sign(delta2)) * min(abs(delta1), abs(delta2), 0.25*abs(delta1 + delta2))
    delta1m1 = delta1 - m1
    delta1m1m2 = m1 + m2 - 2*delta1
    prevdt = dt

    GforceVelCoef = min(1, 1/(abs(wheelvel) + 1))
    M.curForceLimit = curForceLimitSmoother:getWithRate(M.wheelFFBForceLimit, dt, 1)

    local speedT = max(electrics.values.airspeed, abs(electrics.values.wheelspeed)) / ffbSpeedFast
    M.wheelFFBForceCoefCurrent = lerp(M.wheelFFBForceCoefLowSpeed, M.wheelFFBForceCoef, clamp(speedT, 0, 1)) -- approach maxForce as we get closer to the fast speed threshold

    if ai.isDriving() then
      M.wheelFFBForceCoefCurrent = 0 -- free up the wheel while AI is driving
    end
  end

  -- update electrics steering
  if steeringHydro then
    electrics.values.steering = -toInputSpace(steeringHydro, steeringHydro.state) * v.data.input.steeringWheelLock
  end
end

local function update(dtSim)
  -- state: the state of the hydro from -1 to 1
  -- cmd the input value
  -- note: state is scaled to the ratio as the last step
  local hydros = M.hydros
  local hcount = hydroCount

  if FFBHydrosExist then
    local FFBhcount = 0
    local hydroPos = 0
    local realWheelPos = 0
    local simWheelPos = 0

    if FFBID >= 0 and playerInfo.anyPlayerSeated then
      hydros = FFBRest
      hcount = FFBRestCount
      dtInternal = dtInternal + dtSim
      local t = min(1, dtInternal / max(1e-30, lastDt))
      realWheelPos = y1 + dtInternal * (m1 + t*(delta1m1 + (t - 1)*delta1m1m2))

      for i = 1, #FFBHydros do
        local h = FFBHydros[i]

        local hbcid = h.bcid
        if not h.fIsBroken(obj, hbcid) then
          FFBhcount = FFBhcount + 1
          hydroPos = hydroPos + toInputSpace(h, h.fgetDisplacement(obj, hbcid) * h.invFFBHydroRefL)
          simWheelPos = simWheelPos + toInputSpace(h, h.state)
        end

        if h.cmd ~= h.state then -- elide expensive core call
          local statef = realWheelPos * h.inputFactor
          if statef >= h.inputCenter then
            statef = h.cOut + statef * h.multOut
          else
            statef = h.cIn + statef * h.multIn
          end

          if h.cmd < h.state then
            h.state = max(h.state - min(h._inrate, max(0, h.state - statef)), h.cmd)
          else
            h.state = min(h.state + min(h._outrate, max(0, statef - h.state)), h.cmd)
          end
          h.fsetRelDisplacement(obj, h.bcid, h.state)
        end
      end
    end

    FFBcalc((simWheelPos - hydroPos) / max(1, FFBhcount), realWheelPos)
  end

  for i = 1, hcount do
    local h = hydros[i]
    if h.cmd ~= h.state then -- elide expensive core call
      -- slowly approach the desired value
      if h.cmd < h.state then
        h.state = max(h.state - min(h.smoothrate, h._inrate), h.cmd)
      else
        h.state = min(h.state + min(h.smoothrate, h._outrate), h.cmd)
      end
      h.fsetRelDeformedDisplacement(obj, h.bcid, h.state)
    end
  end
end

local function getFFBConfig()
  return {
    forceCoef = M.wheelFFBForceCoef,
    softlockForce = softlockForceCoef,
    smoothing = wheelFFBSmoothing / 0.7,
    smoothing2 = (wheelFFBSmoothing2-500)/109, -- IMPORTANT: these equations exist in 3 places in hydros.lua, 2 places in options.js, and 1 place in bindings.lua
    smoothing2automatic = wheelFFBSmoothing2automatic ~= false,
    gforceCoef = M.GforceCoef,
  }
end

local function setFFBConfig(ffbParams)
  if ffbParams.forceCoef ~= nil then M.wheelFFBForceCoef = ffbParams.forceCoef end
  if ffbParams.softlockForce ~= nil then softlockForceCoef = clamp(ffbParams.softlockForce, 0 ,1) end
  if ffbParams.smoothing ~= nil then wheelFFBSmoothing = ffbParams.smoothing * 0.7 end
  if ffbParams.gforceCoef ~= nil then M.GforceCoef = ffbParams.gforceCoef  end

  wheelFFBSmoothing2automatic = ffbParams.smoothing2automatic ~= false
  -- IMPORTANT: these equations exist in 3 places in hydros.lua, 2 places in options.js, and 1 place in bindings.lua
  if wheelFFBSmoothing2automatic then
    wheelFFBSmoothing2 = max(5000, (500 - wheelFFBSmoothing)*100+5000)
  else
    wheelFFBSmoothing2 = ffbParams.smoothing2 * 109 + 500
  end

  if FFBID >= 0 then
    obj:sendForceFeedback(FFBID, 0)
  end
end

local FFBSafetyData
local function FFBSafetyDataNotifyUI()
  obj:queueGameEngineLua(string.format("extensions.core_input_bindings.setFFBSafetyData(deserialize(%q))", serialize(FFBSafetyData)))
end

local function onFFBConfigChanged(newFFBConfig)
  FFBSafetyData = nil
  if FFBID >= 0 then
    obj:sendForceFeedback(FFBID, 0)
  end
  FFBID = -1
  if #FFBHydros ~= 0 and newFFBConfig and newFFBConfig.steering then
    y1 = 0

    FFBHydrosExist = true
    FFBsmooth:set(0)
    curForceLimitSmoother:set(0)
    log("D", "hydros.init", "Response to FFB config request: "..dumps(newFFBConfig))

    local ffbConfig = newFFBConfig.steering

    if M.enableFFB then
      FFBID = ffbConfig.FFBID or -1
    end

    if FFBID >= 0 then
      if ffbConfig.ff_max_force and ffbConfig.ff_max_force ~= 0 then
        FFmax = max(0.1, ffbConfig.ff_max_force)
        M.wheelFFBForceLimit = FFmax
        if ffbConfig.ff_res == 0 then
          ffbConfig.ff_res = 65536
          log("D", "", "Steering wheel drivers didn't provide any FFB resolution information. Defaulting to "..dumps(ffbConfig.ff_res).. " steps")
        end
        invFFstep = ffbConfig.ff_res / FFmax
        local ffbParams = ffbConfig.ffbParams
        if ffbParams then
          local frequency = 0
          if ffbParams.forceCoef ~= nil then M.wheelFFBForceCoef = ffbParams.forceCoef end
          if ffbParams.softlockForce~= nil then softlockForceCoef = clamp(ffbParams.softlockForce, 0, 1) end
          M.wheelFFBForceCoefLowSpeed = M.wheelFFBForceCoef
          if ffbParams.lowspeedCoef then M.wheelFFBForceCoefLowSpeed = ffbParams.forceCoef / 10 end
          if ffbParams.smoothing ~= nil then wheelFFBSmoothing = ffbParams.smoothing * 0.7 end
          if ffbParams.gforceCoef ~= nil then M.GforceCoef = ffbParams.gforceCoef  end
          if ffbParams.frequency ~= nil then frequency = tonumber(ffbParams.frequency) or 0 end
          responseCorrected = ffbParams.responseCorrected == true
          if ffbParams.responseCurve ~= nil then responseCurve = ffbParams.responseCurve end
          if responseCorrected then
            responseCurve = processResponseCurve(responseCurve)
          end

          wheelFFBSmoothing2automatic = ffbParams.smoothing2automatic ~= false
          -- IMPORTANT: these equations exist in 3 places in hydros.lua, 2 places in options.js, and 1 place in bindings.lua
          if wheelFFBSmoothing2automatic then
            wheelFFBSmoothing2 = max(5000, (500 - wheelFFBSmoothing)*100+5000)
          else
            wheelFFBSmoothing2 = ffbParams.smoothing2 * 109 + 500
          end

          local automaticRate = frequency == 0
          local detectedPeriodMs = ffbConfig.ffbSendms or 1000/60 -- fallback if timing is not available
          local detectedPeriod = detectedPeriodMs / 1000 -- convert from ms to s
          local safePeriod = detectedPeriod * 2.5 -- leave time for actual physics computation too
          local safeFrequency = math.floor(1/safePeriod)
          local finalFrequency
          FFBSafetyData = {}
          FFBSafetyData.isSafeUpdateRate = true
          FFBSafetyData.isSafeUpdateType = ffbParams.updateType == 0
          if automaticRate then
            -- try to not overload the FFB drivers with too many updates
            -- some steering wheels drivers accept 2KHz updates but will show incorrect behaviour, in those cases the automatic detection (frequency == 0) can be overriden with custom rates (frequency > 0)
            finalFrequency = clamp(safeFrequency, 30, 500)
          else
            finalFrequency = math.max(frequency, 1)
            if finalFrequency > safeFrequency then
              log("W", "", "User has chosen a force feedback update rate of "..finalFrequency.." Hz. That's higher than the currently estimated safe value of "..safeFrequency.." Hz. The framerate might severely drop, the steering wheel may respond erroneously, freeze, exhibit wrong force responses, or similar strange side effects")
              FFBSafetyData.isSafeUpdateRate = false
            end
          end
          FFBSafetyData.safeFrequency = safeFrequency
          FFBSafetyData.finalFrequency = finalFrequency
          FFBperiod = 1 / math.floor(finalFrequency + 0.5)
          local msgDriver   = ""..(math.floor(1/detectedPeriod)).."Hz/"..detectedPeriodMs .."ms detected"
          local msgSafe     = ""..(safeFrequency)               .."Hz safe"
          local msgSelected = ""..(frequency)                   .."Hz selected"
          local msgUsed     = ""..(finalFrequency)              .."Hz/".. (FFBperiod*1000) .."ms used"
          log("D", "hydros.init", dumps(v.data.vehicleDirectory)..": Force Feedback motor found for steering hydro. physicsID: "..dumps(obj:getId())..", FFBID: "..dumps(FFBID)..", ForceCoef "..M.wheelFFBForceCoef..", Smoothing "..wheelFFBSmoothing..", Update rate: "..msgDriver..", "..msgSafe..", "..msgSelected..", "..msgUsed.." ("..(automaticRate and "auto" or "manual")..")")
          guihooks.message("Controller with force feedback detected<br>Disabling steering from the other controllers", 5, "hydros")
          obj:sendForceFeedback(FFBID, 0)
          nextDriverUpdate = clockhp() + FFBperiod
        else
          FFBID = -1
          log("E", "hydros.init", "Couldn't find ffbParams in ffbconfig: ffbParams: "..dumps(ffbParams).."\nffbConfig.ffbParams: "..dumps(ffbConfig.ffbParams))
        end
      else
        FFBID = -1
        log("E", "hydros.init", "Couldn't parse FFB config:\n"..dumps(ffbConfig))
      end
    end
  end
  FFBSafetyDataNotifyUI()
end

-- nop'ed functions
M.updateGFX = updateGFX
M.update = update

local function init()
  if v.data.input and v.data.input.FFBcoef ~= nil then
    vehicleFFBForceCoef = v.data.input.FFBcoef * 1.2
  end

  FFBHydros = {}
  FFBRest = {}
  M.hydros = {}

  if v.data.hydros then
    for _, h in pairs(v.data.hydros) do
      h.fIsBroken = obj.beamIsBroken
      h.fgetDisplacement = obj.getBeamLength
      h.fsetRelDisplacement = obj.setBeamLengthRefRatio
      h.fsetRelDeformedDisplacement = obj.setBeamLengthRefDeformedRatio
      h.bcid = h.beamCID
      h.invFFBHydroRefL = 1 / obj:getBeamRefLength(h.bcid)
      h.center = 1
      table.insert(M.hydros, h)
    end
  end

  if v.data.torsionHydros then
    for _, h in pairs(v.data.torsionHydros) do
      h.fIsBroken = obj.torsionbarIsBroken
      h.fgetDisplacement = obj.getTorsionbarAngle
      h.fsetRelDisplacement = obj.setTorsionbarAngle
      h.fsetRelDeformedDisplacement = obj.setTorsionbarAngle
      h.bcid = h.cid
      h.invFFBHydroRefL = 1
      h.center = 0
      table.insert(M.hydros, h)
    end
  end

  for _, h in pairs(M.hydros) do
    h.inputCenter = h.inputCenter * h.inputFactor
    h.inputInLimit = h.inputInLimit * h.inputFactor
    h.inputOutLimit = h.inputOutLimit * h.inputFactor
    local inputFactorSign = sign2(h.inputFactor)

    if h.inputFactor < 0 then
      h.inputInLimit, h.inputOutLimit = h.inputOutLimit, h.inputInLimit
    end

    local inputMiddle = (h.inputOutLimit + h.inputInLimit) * 0.5
    if h.inputCenter >= inputMiddle then
      h.center = h.center + (h.outLimit - 1) * (h.inputCenter - inputMiddle) / (h.inputOutLimit - inputMiddle)
    else
      h.center = h.center - (1 - h.inLimit) * (inputMiddle - h.inputCenter) / (inputMiddle - h.inputInLimit)
    end

    h.multOut = (h.outLimit - h.center) / (h.inputOutLimit - h.inputCenter)
    h.cOut = h.center - h.inputCenter * h.multOut
    h.multIn = (h.center - h.inLimit) / (h.inputCenter - h.inputInLimit)
    h.cIn = h.center - h.inputCenter * h.multIn
    h.cmd = h.inputCenter
    h.invMultOut = 1 / (h.outLimit - h.center) * inputFactorSign
    h.invMultIn = 1 / (h.center - h.inLimit) * inputFactorSign
    h._inrate = h.inRate * physicsDt
    h._outrate = h.outRate * physicsDt
    h.smoothrate = math.huge

    h.state = h.center + 1e-28 -- so as it initializes correctly

    h.inputSource = h.inputSource == "steering" and "steering_input" or h.inputSource
    if h.inputSource == "steering_input" then
      table.insert(FFBHydros, h)
    else
      table.insert(FFBRest, h)
    end

    if h.inputSource == "steering_input" then
      steeringHydro = h
    end

    local iflex = inputFlex[h.inputSource] or {}
    iflex.minRate = min(iflex.minRate or math.huge, h.inRate, h.outRate, h.autoCenterRate or h.inRate)
    iflex.maxRate = max(iflex.maxRate or 0, h.inRate, h.outRate, h.autoCenterRate or h.inRate)
    iflex.offset = 0
    iflex.offsetDiff = 0
    iflex.inLimit = min(iflex.inLimit or math.huge, h.inputInLimit)
    iflex.outLimit = max(iflex.outLimit or -math.huge, h.inputOutLimit)
    inputFlex[h.inputSource] = iflex
  end
  hydroCount = #M.hydros
  FFBRestCount = #FFBRest

  if hydroCount == 0 then
    M.updateGFX = nop
    M.update = nop
  end

  M.reset()
end

local function reset()
  if #M.hydros == 0 then
    M.updateGFX = nop
    M.update = nop
    return
  else
    M.updateGFX = updateGFX
    M.update = update
  end

  for _,h in pairs(M.hydros) do
    h.state = h.center + 1e-28 -- so as it initializes correctly
    h.cmd = h.inputCenter
    h._inrate = h.inRate * physicsDt
    h._outrate = h.outRate * physicsDt
  end

  FFBsmooth:set(0)
  curForceLimitSmoother:set(0)
  if FFBID >= 0 then
    obj:sendForceFeedback(FFBID, 0)
    --TODO: we should probably set the lastDriverUpdate time here, to prevent momentary overload of drivers
  end
end

local function destroy()
  if FFBID >= 0 then
    obj:sendForceFeedback(FFBID, 0)
  end
end

local function sendHydroStateToGUI()
  guihooks.trigger('HydrosUpdate', M.state);
end

local function sendRPMLeds(currentRPM, rpmFirstLedTurnsOn, rpmRedLine)
  if FFBID >= 0 then
    obj:sendRPMLeds(FFBID, currentRPM, rpmFirstLedTurnsOn, rpmRedLine)
  end
end

local function isPhysicsStepUsed()
  return M.update == update
end

-- public interface
M.init = init
M.reset = reset
M.sendHydroStateToGUI = sendHydroStateToGUI
M.onFFBConfigChanged = onFFBConfigChanged
M.getFFBConfig = getFFBConfig
M.setFFBConfig = setFFBConfig
M.sendRPMLeds = sendRPMLeds
M.destroy = destroy
M.isPhysicsStepUsed = isPhysicsStepUsed
M.FFBSafetyDataNotifyUI = FFBSafetyDataNotifyUI
return M
