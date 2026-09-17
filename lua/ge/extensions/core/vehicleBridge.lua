-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This file is meant as a blackbock-communications extension for communicating with vlua.
-- all gameplay-related vlua-requests/functions should go through here.
-- see gameplayInterface.lua on vlua side.
local M = {}

local buffer = require('string.buffer')
local cmdBuf = buffer.new()

M.vehicleData = {}
M.logCommandFunction = function(veh, id, command)
  log("D","","To Vehicle " .. dumps(veh:getId()) .. " -> " .. id .. " -> " ..dumps(tostring(command)))
end
M.logCommand = nop
M.setLogCommands = function(enabled) M.logCommand = enabled and M.logCommandFunction or nop end
M.setLogCommands(false)

-- gets a new unique ID which can be used for callbacks from vlua.
local callbackId = 0
local function getNewCallbackId()
  callbackId = callbackId + 1
  return callbackId
end

local function valueChangedCallback(vehId, data)
  if not M.vehicleData[vehId] then return end
  for key, value in pairs(data) do
    M.vehicleData[vehId].data[key] = value
  end
end

-- gets called from vlua with the id of the callback and the requested data.
local callbacks = {}
local function callbackFromVlua(vehId, callbackId, data)
  local deserializedData = lpack.decode(data)
  if deserializedData.failReason then
    log("E","","Callback with id " .. callbackId.." failed to execute on vehicle side: " .. dumps(deserializedData.failReason))
  end

  if callbackId == -2 then
    valueChangedCallback(vehId, deserializedData)
    return
  end
  if callbacks[callbackId] then
    callbacks[callbackId](deserializedData)
  end
  callbacks[callbackId] = nil
end

local function requestValue(veh, callback, ...)
  if not veh then
    log("E","","Tried requesting value without a vehicle!")
    return
  end
  local id = getNewCallbackId()
  callbacks[id] = callback
  cmdBuf:reset()
  cmdBuf:put("extensions.gameplayInterface.getSystemData(0,")
  cmdBuf:put(id)
  for k, p in ipairs({...}) do
    cmdBuf:put(",")
    cmdBuf:put(serialize(p))
  end
  cmdBuf:put(")")
  --local cmd = string.format("extensions.gameplayInterface.getSystemData(0, %d, %s)", id, table.concat(params, ", "))
  M.logCommand(veh, id, cmdBuf)
  veh:queueLuaCommand(cmdBuf)
end

local function registerValueChangeNotification(veh, electricsKey)
  if not veh then
    log("E","","Tried registerValueChangeNotification without a vehicle!")
    return
  end
  local vehicleId = veh:getId()
  if not M.vehicleData[vehicleId] then
    M.vehicleData[vehicleId] = {
      data = {},
      registeredCallbacks = {}
    }
  end
  if M.vehicleData[vehicleId].registeredCallbacks[electricsKey] then
    return
  end
  local id = getNewCallbackId()
  M.vehicleData[vehicleId].registeredCallbacks[electricsKey] = id
  cmdBuf:reset()
  cmdBuf:putf("extensions.gameplayInterface.registerValueChangeNotification(0,%d,'%s')", id, electricsKey)
  --local cmd = string.format("extensions.gameplayInterface.registerValueChangeNotification(0,%d,'%s')", id, electricsKey)
  --log("D","","Registering for value change notification: " .. cmd)
  M.logCommand(veh, id, cmdBuf)
  veh:queueLuaCommand(cmdBuf)
end

local function unregisterValueChangeNotification(veh, electricsKey)
  if not veh then
    log("E","","Tried unregisterValueChangeNotification without a vehicle!")
    return
  end
  local vehicleId = veh:getId()
  if not M.vehicleData[vehicleId] then
    return
  end
  local id = M.vehicleData[vehicleId].registeredCallbacks[electricsKey]
  if id then
    cmdBuf:reset()
    cmdBuf:putf("extensions.gameplayInterface.unregisterValueChangeNotification(0,%d,'%s')", id, electricsKey)
    --local cmd = string.format("extensions.gameplayInterface.unregisterValueChangeNotification(0,%d,'%s')", id, electricsKey)
    --log("D","","Unregistering for value change notification: " .. cmd)
    M.logCommand(veh, id, cmdBuf)
    veh:queueLuaCommand(cmdBuf)
    M.vehicleData[vehicleId].registeredCallbacks[electricsKey] = nil
  end
end

local function executeAction(veh, ...)
  if not veh then
    log("E","","Tried executing action without a vehicle!")
    return
  end
  if not veh.queueLuaCommand then
    log("E","","Tried executing action on an object without queueLuaCommand!")
    return
  end
  local id = getNewCallbackId()

  --local cmd = string.format("extensions.gameplayInterface.executeAction(0,%d, %s)", id, table.concat(params, ","))
  cmdBuf:reset()
  cmdBuf:put("extensions.gameplayInterface.executeAction(0,")
  cmdBuf:put(id)
  for k, p in ipairs({...}) do
    cmdBuf:put(",")
    cmdBuf:put(serialize(p))
  end
  cmdBuf:put(")")
  M.logCommand(veh, id, cmdBuf)
  veh:queueLuaCommand(cmdBuf)
end

local function getCachedVehicleData(vehId, key)
  if not M.vehicleData[vehId] then return nil end
  return M.vehicleData[vehId].data[key]
end

M.getCachedVehicleData = getCachedVehicleData
M.requestValue = requestValue
M.executeAction = executeAction
M.callbackFromVlua = callbackFromVlua
M.registerValueChangeNotification = registerValueChangeNotification
M.unregisterValueChangeNotification = unregisterValueChangeNotification
M.onVehicleDestroyed = function(id) M.vehicleData[id] = nil end
M.onVehicleReplaced = function(id) M.vehicleData[id] = nil end
return M