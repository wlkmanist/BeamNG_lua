-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = "vehicleActivePooling"

local _uid = 0
local pools = {}
local VehPool = {}

M.logErrors = false

VehPool.__index = VehPool

-- Vehicle pool main components:
-- activeVehs = array of active (visible) vehicles, by id
-- inactiveVehs = array of inactive (invisible) vehicles, by id
-- allVehs = dict of all vehicles, by id (active state = 1, inactive state = 0)
-- total = number of vehicles in pool (cached)
-- maxActiveAmount = number of maximum active vehicles allowed
-- useSceneVehiclesCap = boolean; if true, counts all vehicles in the scene to limit the amount of active vehicles
-- useDistanceMode = boolean; if true, activates or deactivates vehicles based on distance to the camera (this takes priority over other methods)
-- updateActiveStatePostFade = boolean; if true, updates the active state of the vehicle after fading (false if transparent, true if opaque)

-- active and inactive tables are arrays, to preserve insert / remove order

local function getUniqueId()
  _uid = _uid + 1
  return _uid
end

function VehPool:__tostring()
  return "["..self.id.."] active: {"..table.concat(self.activeVehs, ", ").."}"..", inactive: {"..table.concat(self.inactiveVehs, ", ").."}"
end

function VehPool:new(data)
  data = data or {}
  local new = {}

  new.id = data.id or getUniqueId()
  new.name = data.name or "pool" .. new.id
  new.activeVehs = data.activeVehs or {}
  new.inactiveVehs = data.inactiveVehs or {}
  new.allVehs = {}
  new.fadeQueue = {}
  new.maxActiveAmount = data.maxActiveAmount or math.huge
  new.useSceneVehiclesCap = false
  new.useDistanceMode = false
  new.updateActiveStatePostFade = false
  new.activeDistance = 300
  new.fadeDuration = 0.25
  new.total = 0

  setmetatable(new, VehPool)

  for _, v in ipairs(new.activeVehs) do
    new.allVehs[v] = 1
    new.total = new.total + 1
  end
  for _, v in ipairs(new.inactiveVehs) do
    new.allVehs[v] = 0
    new.total = new.total + 1
  end

  local valid = false
  while not valid do -- id validation
    valid = true
    for id, _ in pairs(pools) do
      if id == new.id then
        new.id = getUniqueId()
        valid = false
      end
    end
  end

  return new
end

function VehPool:onSerialize()
  local data = {}
  data.id = self.id
  data.name = self.name
  data.activeVehs = self.activeVehs
  data.inactiveVehs = self.inactiveVehs
  data.allVehs = self.allVehs
  data.fadeQueue = self.fadeQueue
  data.total = self.total
  data.maxActiveAmount = self.maxActiveAmount
  data.useSceneVehiclesCap = self.useSceneVehiclesCap
  data.useDistanceMode = self.useDistanceMode
  data.updateActiveStatePostFade = self.updateActiveStatePostFade
  data.activeDistance = self.activeDistance
  data.fadeDuration = self.fadeDuration

  return data
end

function VehPool:onDeserialized(data)
  if not data then return end
  for k, v in pairs(data) do
    self[k] = v
  end
end

-- returns the total amount of all active vehicles in the scene
function VehPool:getSceneActiveAmount(vehTypes)
  local count = 0
  local filterParked = not vehTypes or arrayFindValueIndex(vehTypes, "PropParked")
  for _, veh in ipairs(getAllVehiclesByType(vehTypes)) do -- if vehTypes is nil, uses default args
    if veh:getActive() and not (filterParked and veh.isParked) then
      count = count + 1
    end
  end

  return count
end

-- returns true if the current active amount limit is reached
function VehPool:checkActiveLimit()
  if self._ignoreActiveAmount or self.maxActiveAmount == math.huge then
    return false
  end
  local activeAmount = self.useSceneVehiclesCap and self:getSceneActiveAmount() or #self.activeVehs
  if activeAmount < self.maxActiveAmount then
    return false
  end

  return true
end

function VehPool:clearPool()
  table.clear(self.activeVehs)
  table.clear(self.inactiveVehs)
  table.clear(self.allVehs)
  table.clear(self.fadeQueue)
  self.total = 0
end

function VehPool:deletePool(keepVehicles)
  if not keepVehicles then
    for k, v in pairs(self.inactiveVehs) do
      local obj = getObjectByID(v)
      if obj then obj:delete() end
    end
  end
  pools[self.id] = nil
  extensions.hook("onVehiclePoolRemoved", self.id)
end

-- inactivates passed vehicle, activates one and returns it
function VehPool:cycle(vehId1, vehId2)
  -- vehId1 and vehId2 are optional, otherwise the first table entry is used
  vehId1 = vehId1 or self.activeVehs[1]
  vehId2 = vehId2 or self.inactiveVehs[1]
  if not vehId1 or not vehId2 or not self.allVehs[vehId1] or not self.allVehs[vehId2] then return false end

  self._ignoreActiveAmount = true -- temporary flag while vehicles are getting processed
  self:setVeh(vehId1, false)
  self:setVeh(vehId2, true)
  self._ignoreActiveAmount = nil
  return vehId1, vehId2
end

-- sets a vehicle as inactive from this pool and activates one from another pool
function VehPool:crossCycle(otherPool, vehId1, vehId2)
  if not otherPool or self.id == otherPool.id then return self:cycle(vehId1, vehId2) end

  vehId1 = vehId1 or self.activeVehs[1]
  vehId2 = vehId2 or otherPool.inactiveVehs[1]
  if not vehId1 or not vehId2 or not self.allVehs[vehId1] or not self.allVehs[vehId2] then return false end

  self:setVeh(vehId1, false)
  otherPool:setVeh(vehId2, true)
  return vehId1, vehId2
end

-- directly increases or decreases the vehicle mesh alpha, returning the new alpha
-- use this during runtime for a smooth transition
function VehPool:fadeVeh(vehId, dt)
  if not self.allVehs[vehId] or not be:getObjectActive(vehId) then return -1 end -- vehicle needs to be in the pool and active

  local obj = getObjectByID(vehId)
  local alpha = clamp(obj:getMeshAlpha('') + dt, 0, 1)
  obj:setMeshAlpha(alpha, '')

  return alpha
end

-- smoothly fades a vehicle mesh to opaque
function VehPool:fadeInVeh(vehId)
  if not self.allVehs[vehId] then return false end

  if not be:getObjectActive(vehId) then
    if self.updateActiveStatePostFade then
      local valid = self:setVeh(vehId, true)
      if M.logErrors and self.useDistanceMode then
        log("W", logTag, "Distance mode is enabled, taking priority over other activate / deactivate methods")
      end
      if not valid then return false end
    else
      return false
    end
  end

  self.fadeQueue[vehId] = 1
  return true
end

-- smoothly fades a vehicle mesh to transparent
function VehPool:fadeOutVeh(vehId)
  if not self.allVehs[vehId] or not be:getObjectActive(vehId) then return false end

  self.fadeQueue[vehId] = 0
  return true
end

-- returns true if successfully inserted the new active vehicle
function VehPool:tryInsertActiveVeh(vehId, forceInsert)
  if self:checkActiveLimit() then
    if forceInsert then
      self.maxActiveAmount = self.maxActiveAmount + 1
    else
      if M.logErrors then log("W", logTag, "Trying to activate a vehicle but the amount of maximum active vehicles has been reached") end
      return false
    end
  end

  return true
end

-- returns true if successful insert
function VehPool:insertVeh(vehId, forceInsert)
  local obj = getObjectByID(vehId)
  if not obj then return false end
  if self.allVehs[vehId] then
    if M.logErrors then log("W", logTag, "The vehicle with id: " .. vehId .. " is already inserted in this pool") end
    return false
  end

  local state
  if obj:getActive() then
    state = self:tryInsertActiveVeh(vehId, forceInsert) and "activeVehs" or "inactiveVehs"
  else
    state = "inactiveVehs"
  end
  if state then
    table.insert(self[state], vehId)
    self.allVehs[vehId] = state == "activeVehs" and 1 or 0
    self.total = self.total + 1
    obj:setActive(state == "activeVehs" and 1 or 0) -- triggers VehPool:_setVeh
  end

  return state and true or false
end

-- returns true if successful removal
function VehPool:removeVeh(vehId)
  if not self.allVehs[vehId] then return false end

  local result = arrayFindValueIndex(self.activeVehs, vehId)
  local state
  if result then
    state = "activeVehs"
  else
    result = arrayFindValueIndex(self.inactiveVehs, vehId)
    if result then
      state = "inactiveVehs"
    end
  end
  if state then
    table.remove(self[state], result)
    self.allVehs[vehId] = nil
    self.total = self.total - 1
  end

  return state and true or false
end

--returns true if activated/deactivated at least one vehicle
function VehPool:setAllVehs(activate)
  -- tables are temporarily copied due to asynchronous change of vehicle active state
  if activate then
    if not self.inactiveVehs[1] then return false end

    local limit = self.maxActiveAmount - #self.activeVehs

    for _, v in ipairs(deepcopy(self.inactiveVehs)) do
      if limit <= 0 then break end
      limit = limit - 1
      self:setVeh(v, true)
    end
    return true
  else
    if not self.activeVehs[1] then return false end
    for _, v in ipairs(deepcopy(self.activeVehs)) do
      self:setVeh(v, false)
    end
    return true
  end
end

-- internal active state manager, do not call this
function VehPool:_setVeh(vehId, activate)
  if not self.allVehs[vehId] then return end

  if (activate and self.allVehs[vehId] == 1) or (not activate and self.allVehs[vehId] == 0) then
    if M.logErrors then log("W", logTag, "Vehicle with id ".. vehId .. " is already " .. (activate and "activated" or "deactivated")) end
    return
  end

  if activate then
    table.remove(self.inactiveVehs, arrayFindValueIndex(self.inactiveVehs, vehId))
    table.insert(self.activeVehs, vehId)
    self.allVehs[vehId] = 1
  else
    table.remove(self.activeVehs, arrayFindValueIndex(self.activeVehs, vehId))
    table.insert(self.inactiveVehs, vehId)
    self.allVehs[vehId] = 0
  end
end

-- returns true if successful toggle
-- forceInsert is used when the maxActiveAmount is reached, if yes it will increase the limit
function VehPool:setVeh(vehId, activate, forceInsert)
  if not self.allVehs[vehId] then return false end

  if (activate and self.allVehs[vehId] == 1) or (not activate and self.allVehs[vehId] == 0) then
    if M.logErrors then log("W", logTag, "Vehicle with id ".. vehId .. " is already " .. (activate and "activated" or "deactivated")) end
    return false
  end

  if activate then
    if self:tryInsertActiveVeh(vehId, forceInsert) then
      getObjectByID(vehId):setActive(1)
    else
      return false
    end
  else
    getObjectByID(vehId):setActive(0)
  end

  return true
end

-- sets the maximum amount of active vehicles allowed
function VehPool:setMaxActiveAmount(amount)
  self.maxActiveAmount = amount or self.maxActiveAmount

  if not self:checkActiveLimit() then return end

  local activeAmount = self.useSceneVehiclesCap and self:getSceneActiveAmount() or #self.activeVehs
  local difference = activeAmount - self.maxActiveAmount

  if difference > 0 then -- hide some active vehicles
    local tempActiveVehs = deepcopy(self.activeVehs)
    for i = 1, difference do
      if tempActiveVehs[i] then
        self:setVeh(tempActiveVehs[i], false)
      end
    end
  end
end

-- activates or deactivates vehicles with respect to their distance to the target position and max distance
local vehPos = vec3()
function VehPool:activateByDistanceTo(pos, dist, buffer)
  pos = pos or core_camera.getPosition()
  dist = dist or self.activeDistance
  buffer = buffer or 10

  for id, state in pairs(self.allVehs) do
    local obj = getObjectByID(id)
    if obj then
      vehPos:set(obj:getPositionXYZ())

      if state == 1 and vehPos:squaredDistance(pos) > square(dist + buffer) then -- buffer prevents rapid activation / deactivation cycles
        obj:setActive(0)
      end
      if state == 0 and vehPos:squaredDistance(pos) <= square(dist) then
        obj:setActive(1)
      end
    end
  end
end

function VehPool:getVehs()
  return arrayConcat(deepcopy(self.activeVehs), self.inactiveVehs)
end

---- Manager ----

local function createPool(data)
  local pool = VehPool:new(data)
  pools[pool.id] = pool
  extensions.hook("onVehiclePoolAdded", pool.id)
  return pool
end

local function deletePool(id)
  pools[id] = nil
end

local function getPool(name)
  if not name then return end
  for _, pool in pairs(pools) do
    if pool.name == name then return pool end
  end
end

local function getPoolOfVeh(vehId)
  for id, pool in pairs(pools) do
    if pool.allVehs[vehId] then
      return pool, pool.allVehs[vehId] == 1
    end
  end
end

local function getPoolById(id)
  return id and pools[id]
end

local function getAllPools()
  return pools
end

local function deleteAllPools()
  for _, pool in pairs(pools) do
    pool:deletePool()
  end
  pools = {}
end

local function onVehicleActiveChanged(vehId, active)
  for _, pool in pairs(pools) do
    pool:_setVeh(vehId, active)
  end
end

local function onVehicleDestroyed(vehId)
  for _, pool in pairs(pools) do
    pool:removeVeh(vehId)
  end
end

local function onClientEndMission()
  deleteAllPools()
end

local function onUpdate(dt, dtSim)
  if not next(pools) then return end

  for _, pool in pairs(pools) do
    if pool.useDistanceMode then
      pool:activateByDistanceTo()
    end

    for vehId, state in pairs(pool.fadeQueue) do
      if state == 1 then -- fade in
        local alpha = pool:fadeVeh(vehId, dtSim / math.max(1e-12, pool.fadeDuration))
        if alpha == 1 then
          pool.fadeQueue[vehId] = nil
        end
      elseif state == 0 then -- fade out
        local alpha = pool:fadeVeh(vehId, -dtSim / math.max(1e-12, pool.fadeDuration))
        if alpha == 0 then
          pool.fadeQueue[vehId] = nil
          if pool.updateActiveStatePostFade then
            pool:setVeh(vehId, false)
            if M.logErrors and pool.useDistanceMode then
              log("W", logTag, "Distance mode is enabled, taking priority over other activate / deactivate methods")
            end
          end
        end
      end
    end
  end
end

local function onSerialize()
  local data = {}
  for _, pool in pairs(pools) do
    table.insert(data, pool:onSerialize())
  end

  return data
end

local function onDeserialized(data)
  for _, v in ipairs(data) do
    local pool = createPool()
    pool:onDeserialized(v)
  end
end

M.createPool = createPool
M.deletePool = deletePool
M.getPool = getPool
M.getPoolById = getPoolById
M.getPoolOfVeh = getPoolOfVeh
M.getAllPools = getAllPools
M.deleteAllPools = deleteAllPools

M.onVehicleActiveChanged = onVehicleActiveChanged
M.onVehicleDestroyed = onVehicleDestroyed
M.onClientEndMission = onClientEndMission
M.onUpdate = onUpdate
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M