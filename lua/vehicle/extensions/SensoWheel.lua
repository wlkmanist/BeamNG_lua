-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"tech_CANBus_CANBusPeak"}

-- BEGIN: User settings
  -- Adjust updateTime to get the best performance.
  --If too high, then queuing of CAN messages occures, what leads to lag of input. If too low, then response is not accurate
  local updateTime = 1/10                         -- [s]
  -- If SensoWheel is unstable when vehicle is not moving, adjust base friction and damping
  local SensoWheelBaseSpringStiffness = 0 --10        -- Range: 0 - 2500 [mNm/°]
  local SensoWheelBaseDamping = 0 -- 5                -- Range: 0 - 500 [mNm/rpm]
  local SensoWheelBaseFriction = 0 -- 50              -- Range: 0 - 5000 [mNm]
  local forceFeedbackLowSpeedReduction = false        -- true
  local nativeSoftlock = false                        -- true
  -- Force Feedback parameters
  local forceFeedbackGain = 1                     -- Gain multiplier for force feedback (range 0 - 1)
  -- Use SensoWheel GUI to find pedals range and adjust it accordingly
  local throttlePedalPositionMin = 500            -- Throttle pedal value - pedal released
  local throttlePedalPositionMax = 3000           -- Throttle pedal value - pedal fully pressed
  local brakePedalPositionMin = 75                -- Brake pedal value - pedal released
  local brakePedalPositionMax = 500               -- Brake pedal value - pedal fully pressed
  -- SensoWheel mode
  local SensoWheelModeOfOpeartion = 0x10          -- SensoWheel mode of operation (0x10 = Normal Mode, 0x20 = Basic Mode)
  -- BeamNG settings
  local ffbSmoothing = 10                         -- filtering FFB command
  -- END: User settings

  local max = math.max
  local min = math.min

  local canBus
  local baudrate = 0x0014;  -- PEAK Baudrate

  local SWTimer = 0
  local SWTime = updateTime
  local updateTimer = 1

  local firstStep = 0
  local SWstate = 0x00
  local rawPosition = 0x00000000
  local controlWord = 0x00
  local auxiliaryFunctions = 0x00                           -- SensoWheel CAN Watchdog 0x01 = off
  local endStopPositions1, endStopPositions2  = 0x00, 0x00  -- SensoWheel Endstops = 0x000 = no endstops active
  local positionOffset1, positionOffset2 = 0x00, 0x00       -- SensoWheel position offset = 0x0000 = 0
  local torqueLimitation = 0xFF                             -- SensoWheel torque limitation = 0xFF = 255%
  local peakTorqueLimitation = 0x64                         -- SensoWheel peak torque limitation = 0x64 = 100%

  local SWposition = 0x00
  local throttlePedalPosition = 0x0000
  local brakePedalPosition = 0x0000
  local clutchPedalPosition = 0x0000

  local torque = 0
  local SWactualTorque = 0
  local swON = false

-- Define CAN message IDs
local messageIds = {
  sendForceFeedback = 0x201,              -- ID for sending force feedback torque in normal mode
  receiveWheelPosition = 0x211,           -- ID for receiving the steering wheel position
  sendForceFeedbackBasicMode = 0x202,     -- ID for sending force feedback torque in basic mode
  receiveWheelPositionBasicMode = 0x212,  -- ID for receiving the steering wheel position in basic mode
  sendStatus = 0x200,                     -- ID for Control Module message
  recieveStatus = 0x210,                  -- ID for Control Module response
  sendVehicleModelMessage = 0x207,        -- ID for Basic Vehicle Model
  recieveVehicleModelFeedback = 0x217,    -- ID for Basic Vehicle Model feedback
  sendPedalsStateRequest = 0x20C,         -- ID for Requesting Peripherals: pedals
  recievePedalsState = 0x21C              -- ID for Actual values of peripherals: pedals
}

-- Define Dummy CAN message
local messageData = {
  byte0= 0x00,
  byte1= 0x00,
  byte2= 0x00,
  byte3= 0x00,
  byte4= 0x00,
  byte5= 0x00,
  byte6= 0x00,
  byte7= 0x00
}
-- Define Steering CAN message
local steeringMessage= {
  byte0= 0x00,
  byte1= 0x00,
  byte2= 0x00,
  byte3= 0x00,
  byte4= 0x00,
  byte5= 0x00,
  byte6= 0x00,
  byte7= 0x00
}

local NormalModeMessage= messageData
local ControlModuleMessage = messageData
local controlModuleMessage = {controlWord, auxiliaryFunctions, endStopPositions1, endStopPositions2, positionOffset1, positionOffset2, torqueLimitation, peakTorqueLimitation}

local frictionCoefficient = 0.1 -- Friction coefficient, simulating road resistance

-- Steering Wheel State
local steeringWheelPosition = 0 -- Current position of the steering wheel (in degrees)
local steeringAngle = 1 -- Current normalised position (range -1, 1)

-- Init SensoWHeel
local function initSensoWheel()
  forceFeedbackGain = max(min(forceFeedbackGain, 1), 0)    -- ensure that forceFeedbackGain is between 0 - 1
  NormalModeMessage.byte2, NormalModeMessage.byte3 = canBus.twoBytes(SensoWheelBaseFriction)
  NormalModeMessage.byte4, NormalModeMessage.byte5 = canBus.twoBytes(max(0, SensoWheelBaseDamping))
  NormalModeMessage.byte6, NormalModeMessage.byte7 = canBus.twoBytes(max(0, SensoWheelBaseSpringStiffness))
  if nativeSoftlock then
    endStopPositions1, endStopPositions2 = canBus.twoBytes(v.data.input.steeringWheelLock)
  end
  log("I", "SensoWheel.initSensoWheel", "SensoWheel Initialized")
end

-- Currently not in use -- Function to send the desired torque to the steering wheel via CAN
local sendTorqueTmpArray = {}
local lastSendTime = 0
-- Currently not in use -- Function to send the desired torque to the steering wheel via CAN
local function sendTorqueToSteeringWheel(FFBtorque)
  local currentTime = os.clockhp()
  local ffbRequestCycle = 0.001  -- default message cycle 1 ms
  if SensoWheelModeOfOpeartion == 0x20 then end -- message cycle for basic mode
  ffbRequestCycle = 0.001
  if currentTime - lastSendTime < ffbRequestCycle then return end -- maintain update rate
  lastSendTime = currentTime

  if forceFeedbackLowSpeedReduction and obj:getGroundSpeed()*3.6 < 10 then -- vehicle speed lower than 10 kmh
    FFBtorque = FFBtorque * max(0.1, min(((obj:getGroundSpeed()*3.6)*0.1),1)) --* 0.1
  end
  -- log("I", "UpdateFFB", "FFB: " ..FFBtorque)
  if SensoWheelModeOfOpeartion == 0x10 then
    NormalModeMessage.byte0, NormalModeMessage.byte1 = canBus.twoBytes(-FFBtorque * 1000 * forceFeedbackGain)
    sendTorqueTmpArray[1] = NormalModeMessage.byte0
    sendTorqueTmpArray[2] = NormalModeMessage.byte1
    sendTorqueTmpArray[3] = NormalModeMessage.byte2
    sendTorqueTmpArray[4] = NormalModeMessage.byte3
    sendTorqueTmpArray[5] = NormalModeMessage.byte4
    sendTorqueTmpArray[6] = NormalModeMessage.byte5
    sendTorqueTmpArray[7] = NormalModeMessage.byte6
    sendTorqueTmpArray[8] = NormalModeMessage.byte7
    canBus.sendCANMessage(messageIds.sendForceFeedback, sendTorqueTmpArray, "NormalMode")
  elseif SensoWheelModeOfOpeartion == 0x20 then
    local basicModeData = {canBus.twoBytes(-FFBtorque * 1000 * forceFeedbackGain)}
    canBus.sendCANBusRaw(messageIds.sendForceFeedbackBasicMode, basicModeData, 0x00, 0x51)
  end
end

-- Function to update steering wheel position in simulation
local function updateSteeringWheelPosition()
  if SWposition > 0x7FFFFFFF then
    -- If the number is greater than 0x7FFFFFFF, it's negative
    rawPosition = SWposition - 0x100000000
  else
    rawPosition = SWposition
  end
  steeringAngle = ((rawPosition) * (360/40000) / (v.data.input.steeringWheelLock)) -- Convert from raw value to degrees
  steeringAngle = clamp(steeringAngle, -1, 1)
end

-- Function to transit SensoWheel statemachine from OFF to ON
local function startSensoWheel()
  local actualSWstate = bit.band(SWstate, 0xf)
  log("I", "SensoWheelStart", "actualSWstate: " ..actualSWstate)
  if actualSWstate == 0 then
    controlWord = bit.bor(SensoWheelModeOfOpeartion, 0x02)
    log("I", "SensoWheel.startSensoWheel", "SensoWheel in OFF STATE")
    swON = false
  elseif actualSWstate == 2 then
    controlWord = bit.bor(SensoWheelModeOfOpeartion, 0x04)
    log("I", "SensoWheel.startSensoWheel", "SensoWheel in READY STATE")
    swON = false
  elseif actualSWstate == 4 then
    controlWord = bit.bor(SensoWheelModeOfOpeartion, 0x04)
  log("I", "SensoWheel.startSensoWheel", "SensoWheel in ENABLE STATE")
  swON = true
  else
    controlWord = bit.bor(SensoWheelModeOfOpeartion, 0x0F)
    log("I", "SensoWheel.startSensoWheel", "SensoWheel in ERROR STATE")
    swON = false
  end
  controlModuleMessage = {controlWord, auxiliaryFunctions, endStopPositions1, endStopPositions2, positionOffset1, positionOffset2, torqueLimitation, peakTorqueLimitation}
  canBus.sendCANMessage(messageIds.sendStatus, controlModuleMessage, "ControlModule")
  log("I", "SensoWheelStart", "State: " ..SWstate)
end

-- Function to transit SensoWheel statemachine from ON to OFF
local function stopSensoWheel()
  local actualSWstate = bit.band(SWstate, 0xf)
  log("I", "SensoWheelStop", "actualSWstate: " ..actualSWstate)
  if actualSWstate == 0x04 then
   log("I", "SensoWheel.stopSensoWheel", "SensoWheel in ENABLE STATE")
    controlWord = bit.bor(SensoWheelModeOfOpeartion, 0x02)
    swON = true
  elseif actualSWstate == 0x00 then
    log("I", "SensoWheel.stopSensoWheel", "SensoWheel in OFF STATE")
    controlWord = bit.bor(SensoWheelModeOfOpeartion, 0x00)
    swON = false
  elseif actualSWstate == 0x02 then
    log("I", "SensoWheel.stopSensoWheel", "SensoWheel in READY STATE")
    controlWord = bit.bor(SensoWheelModeOfOpeartion, 0x00)
    swON = false
  else
    controlWord = bit.bor(SensoWheelModeOfOpeartion, 0x0F)
    log("I", "SensoWheel.stopSensoWheel", "SensoWheel ERROR STATE")
    swON = false
  end
  controlModuleMessage = {controlWord, auxiliaryFunctions, endStopPositions1, endStopPositions2, positionOffset1, positionOffset2, torqueLimitation, peakTorqueLimitation}
  canBus.sendCANMessage(messageIds.sendStatus, controlModuleMessage, "ControlModule")
end

-- Function to request the pedals state
local function requestPedalsState()
  local peripherals = {0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}
  canBus.sendCANBusRaw(messageIds.sendPedalsStateRequest, {0x01}, 0x00, 0x51) -- sends message 0x20C
end

-- Funtion to normalise pedals position and send to inputs
local function updatePedals()
  local throttlePedalPositionNormalized = max(0, min(1,(throttlePedalPosition - throttlePedalPositionMin)/throttlePedalPositionMax))
  local brakePedalPositionNormalized = max(0, min(1,(brakePedalPosition - brakePedalPositionMin)/brakePedalPositionMax))
  input.event("throttle", throttlePedalPositionNormalized, FILTER_DIRECT)
  input.event("brake", brakePedalPositionNormalized, FILTER_DIRECT)
  -- log("I", "UpdatePedals", "Throttle: " ..throttlePedalPosition)
  -- log("I", "UpdatePedals", "Brake: " ..brakePedalPositionNormalized)
end

-- CAN message recieved callback
local function canMessageReceived(msg)
  if msg.ID == messageIds.recieveStatus then   -- message 0x210 recieved
    SWstate = msg.DATA[0]
  elseif msg.ID == messageIds.receiveWheelPosition then  -- -- message 0x211 recieved
    SWposition = (msg.DATA[3] * 256^3) + (msg.DATA[2] * 256^2) + (msg.DATA[1] * 256) + msg.DATA[0]
    SWactualTorque = ((msg.DATA[7] * 256) + msg.DATA[6])/1000
  elseif msg.ID == messageIds.receiveWheelPositionBasicMode then    -- message 0x212 recieved
    SWposition = (msg.DATA[3] * 256^3) + (msg.DATA[2] * 256^2) + (msg.DATA[1] * 256) + msg.DATA[0]
  elseif msg.ID == messageIds.recievePedalsState then  -- message 0x21C recieved
    throttlePedalPosition = (msg.DATA[3] * 256) + msg.DATA[2]
    brakePedalPosition = (msg.DATA[5] * 256) + msg.DATA[4]
    clutchPedalPosition = (msg.DATA[7] * 256) + msg.DATA[6]
  elseif msg.ID == messageIds.recieveVehicleModelFeedback then  -- message 0x217
    SWposition = (msg.DATA[3] * 256^3) + (msg.DATA[2] * 256^2) + (msg.DATA[1] * 256) + msg.DATA[0]
  else
    log("E", "CANBus", "Received nil message")
  end
end

local function sendSteerAngle()
  if not canBus.isConnected then return 0 end
  while true do
    local retCode, msg = canBus.receiveCANBus()
    if retCode ~= canBus.errorCodes.OK then break end
    canMessageReceived(msg)
  end
  updateSteeringWheelPosition()
  return steeringAngle
end

local function captureFFBForces(tmp1,tmp2,trq)
  torque = trq
  sendTorqueToSteeringWheel(torque)
end

-- Update function to be called every frame
local function updateGFX(dt)
  if dt < 0.001 then return end
  if playerInfo.firstPlayerSeated then
    if canBus then
      if swON == false then      --transit SensoWheel to Enabled State
        startSensoWheel()
      end
      SWTimer = SWTimer + dt
        updateTimer = updateTimer + dt
      if SWTimer >= SWTime then
        requestPedalsState()
        SWTimer = 0
      end
      if updateTimer >= updateTime then
        updatePedals()
        updateTimer =0
      end
    end
  else
    if bit.band(SWstate, 0xf)  ~= 0x00 then      --transit SensoWheel to OFF State
      stopSensoWheel()
    end
  end
  guihooks.graph({"Steering", steeringAngle, 1.2, "-",true},{"FFB torque", torque, 20, "-",true})
end

-- Function to be called when the extension is loaded
local function onExtensionLoaded()
  hydros.setFFBConfig({smoothing = ffbSmoothing})
  log("I", "SensoWheel.onExtensionLoaded", "CANBus Force Feedback Steering extension loaded")
  canBus = extensions.tech_CANBus_CANBusPeak
  log("D", "SensoWheel.onExtensionLoaded", "CANBus object type: " .. type(canBus))
  if canBus then
    log("D", "SensoWheel.onExtensionLoaded", "CANBus extension found")
    if not canBus.isConnected then
      log("D", "SensoWheel.onExtensionLoaded", "CANBus extension is not connected, connecting now...")
      local connectionResult = canBus.initCANBus(0x51,  baudrate)
      if connectionResult ~= canBus.errorCodes.OK then
        log("E", "SensoWheel.onExtensionLoaded", "Non-OK init result for CAN Bus, shutting down... Result: " .. canBus.errorCodeLookup[connectionResult])
        canBus = nil
      end
    end
  else
    log("E", "SensoWheel.onExtensionLoaded", "CANBus extension NOT found. Force Feedback won't work...")
  end

  hydros.enableVirtualWheel(true, sendSteerAngle, captureFFBForces)
  log("I", "SensoWheel.onExtensionLoaded", "Virtual Wheel enabled")
  dump("Loading SensoWHeel extension")
  -- Ensure the vehicle and hydraulic data are available
  if v and v.data and v.data.hydros then
    -- Loop through each hydraulic element in the hydros table
    for i, hydro in ipairs(v.data.hydros) do
      --print("Hydro #" .. i)
      -- Loop through all subparameters inside each hydro component
      if hydro then
        for param, value in pairs(hydro) do
          -- Print the name and value of each subparameter in the hydro component
          --  print("  " .. param .. ": " .. tostring(value))
        end
        if hydro.inputSource == "steering_input" then
          -- SensoWheelBaseDamping = hydro.beamDamp -- N*s/m
          print("SensoWheelBaseDamping set to: " ..SensoWheelBaseDamping)
        end
      end
    end
  else
    print("Hydraulic data not found!")
  end
  initSensoWheel()
end

-- Public interface
M.onExtensionLoaded = onExtensionLoaded
M.updateGFX = updateGFX

return M