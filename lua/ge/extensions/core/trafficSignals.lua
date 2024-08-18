-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Traffic Signals V2

local M = {}

local logTag = 'trafficSignals'
local instances, controllers, sequences, mapNodeSignals, signalObjectsDict, controllerDefinitions = {}, {}, {}, {}, {}, {}
local instancesByName, controllersByName, sequencesByName, elementsById = {}, {}, {}, {}
local lightOff, lightOn = '0 0 0 1', '1 1 1 1'
local timer = -1
local loaded = false
local active = false
local delayActive = true
local viewDistSq = 90000
local vecUp = vec3(0, 0, 1)

local queue = require('graphpath').newMinheap()
local signalUpdates = {}

local debugColors = {
  black = ColorF(0, 0, 0, 1),
  red = ColorF(1, 0, 0, 1),
  white = ColorF(1, 1, 1, 0.4),
  green = ColorF(0.25, 1, 0.25, 0.4)
}
local debugPos = vec3()

M.debugLevel = 0

-- WIP signal actions enumeration (send index num to vLua)
-- 0 = none ('go')
local signalActions = {
  alert = 1,
  stop = 2,
  briefStop = 3,
  slow = 4
}

-- mimic colors based on real world, used for debug draws (not for the actual signal objects, which use their own palettes)
local signalColors = {
  red = ColorF(1, 0.2, 0, 1),
  amber = ColorF(1, 0.6, 0, 1),
  yellow = ColorF(1, 0.8, 0, 1),
  green = ColorF(0, 1, 0.5, 1),
  cyan = ColorF(0, 1, 0.9, 1),
  blue = ColorF(0.3, 0.8, 1, 1),
  white = ColorF(1, 1, 1, 1),
  black = ColorF(0, 0, 0, 1)
}

local _uid = 0
local function getNextId() -- increments and generates a new id for the next element
  _uid = _uid + 1
  return _uid
end

local function getElementById(id) -- returns the element (instance, controller, or sequence) via its unique id
  return elementsById[id or 0]
end

local function setupSignalObjects() -- sets and caches the table of TSStatics that are used as signals
  table.clear(signalObjectsDict)

  local statics = getObjectsByClass('TSStatic')
  if statics then
    for _, obj in ipairs(statics) do -- search for static objects with dynamic data
      local instanceName = obj.signalInstance -- signal instance dynamic field
      if instanceName then
        signalObjectsDict[instanceName] = signalObjectsDict[instanceName] or {}
        table.insert(signalObjectsDict[instanceName], obj:getId())
      end
    end
  end
end

---- Traffic signal classes ----

-- Signal Instance
-- Contains a single signal object with a position, direction, controller id, and sequence id
local SignalInstance = {}
SignalInstance.__index = SignalInstance

-- Signal Controller
-- Contains signal type and state data
-- This can be used within multiple signal sequences
local SignalController = {}
SignalController.__index = SignalController

-- Signal Sequence
-- Makes an array of controllers to run in a sequence; each object manages its own states
-- This can be applied to multiple signal instances
local SignalSequence = {}
SignalSequence.__index = SignalSequence

function SignalInstance:new(data)
  local o = {}
  data = data or {}
  setmetatable(o, self)

  o.id = data.id or getNextId()
  o.name = data.name or 'signal'
  o.pos = data.pos or core_camera.getPosition()
  o.dir = data.dir or vec3()
  o.radius = data.radius or 8 -- usually unused
  o.controllerId = data.controllerId or 0 -- controller is required
  o.sequenceId = data.sequenceId or 0 -- sequence is optional, usually used for dynamic signals (traffic lights)
  o.useCurrentLane = data.useCurrentLane -- unused at the moment
  o.startDisabled = data.startDisabled and true or false

  if o.dir:squaredLength() == 0 then -- if dir is (0, 0, 0), try to automatically calculate it based on the closest road
    o.road = o:getBestRoad()
    if o.road then
      o.dir = vec3(o.road.dir)
    end
  end

  return o
end

function SignalInstance:setLights(lightsTable) -- directly sets the lights of all linked signal objects (signal state does not change)
  -- generally, this is only used internally
  if not self.linkedObjects then return end
  lightsTable = lightsTable or {'black', 'black', 'black'}

  local instanceKeys = {}
  for i, _ in ipairs(lightsTable) do
    table.insert(instanceKeys, i > 1 and 'instanceColor'..tostring(i - 1) or 'instanceColor') -- 'instanceColor', 'instanceColor1', etc.
  end

  for _, id in ipairs(self.linkedObjects) do -- actual traffic signal objects
    local obj = scenetree.findObjectById(id)
    if obj then
      for i, light in ipairs(lightsTable) do
        obj:setField(instanceKeys[i], '0', light == 'black' and lightOff or lightOn)
      end
    end
  end
end

function SignalInstance:setStrictState(stateIdx) -- manually sets the signal state from the controller index (overrides auto state)
  -- recommended to use this after disabling the sequence timer; otherwise, the timer will interfere
  local ctrl = self:getController()
  if ctrl then
    self.priorityStateIndex = stateIdx
    if stateIdx and stateIdx > 0 then
      signalUpdates[self.name] = ctrl.states[stateIdx] and ctrl.states[stateIdx].state or 'none'
    else
      self:setActive(true) -- if stateIdx is nil, reset the signal to its expected state
    end
  end
end

function SignalInstance:getSignalObjects(refresh) -- returns table of objects that are used as signals, as ids
  if refresh or not next(signalObjectsDict) then setupSignalObjects() end
  return signalObjectsDict[self.name] or {}
end

function SignalInstance:setSignalObjects(idArray) -- sets objects that will be synced to this signal instance
  for _, id in ipairs(idArray) do
    if scenetree.findObjectById(id) then
      scenetree.findObjectById(id):setDynDataFieldbyName('signalInstance', 0, self.name)
    end
  end
end

function SignalInstance:createSignalObject(shapeFile, pos, rot) -- creates and processes a signal object for this signal instance
  -- we should have a signal head that can be commonly used in any level
  --shapeFile = shapeFile or ''
  if not FS:fileExists(shapeFile) then
    local artDir = path.split(getMissionFilename()) or ''
    artDir = artDir..'art/shapes/'
    for _, f in ipairs(FS:findFiles(artDir, '*', -1, true, false)) do
      if string.find(f, shapeFile) then
        shapeFile = f
        break
      end
    end
    if not FS:fileExists(shapeFile) then
      log('E', logTag, 'Unable to find given shape file!')
      return
    end
  end
  pos = pos or core_camera.getPosition()
  rot = rot or core_camera.getQuat()

  local obj = createObject('TSStatic')
  obj.useInstanceRenderData = false
  obj:setField('shapeName', 0, shapeFile)
  obj:setField('dynamic', 0, 'true')
  obj:setField('collisionType', 0, 'None')
  obj:setField('decalType', 0, 'None')
  obj:setField('annotation', 0, 'TRAFFIC_SIGNALS')
  obj:registerObject()

  local transform = QuatF(rot.x, rot.y, rot.z, rot.w):getMatrix()
  transform:setPosition(pos)
  obj:setTransform(transform)
  obj:setDynDataFieldbyName('signalInstance', 0, self.name)

  if scenetree.MissionGroup then
    local group = scenetree.AutoTrafficSignals
    if not group then
      group = createObject('SimGroup')
      group:registerObject('AutoTrafficSignals')
      group.canSave = false -- unsure if this should be true or false
      scenetree.MissionGroup:addObject(group.obj)
    end

    scenetree.AutoTrafficSignals:addObject(obj.obj)
  end
end

function SignalInstance:setup(pos, dir, controllerId, sequenceId) -- alternative way to set up a signal; creates controller and sequence if needed
  self.pos = pos or self.pos
  self.dir = dir or self.dir
  self.road = self:getBestRoad()

  self.controllerId = controllerId or 0
  if not self.controllerId or not elementsById[self.controllerId] or not elementsById[self.controllerId].states then
  -- if creating a new controller, it will use the default signal type, "lightsBasic"
    self.controller = SignalController:new()
    self.controller:applyDefinition('lightsBasic')
    self.controllerId = self.controller.id
  end

  self.sequenceId = sequenceId or 0
  if not self.sequenceId or not elementsById[self.sequenceId] or not elementsById[self.sequenceId].phases then
    self.sequence = SignalSequence:new()
    self.sequenceId = self.sequence.id
  end
end

function SignalInstance:getBestRoad(pos) -- gets data from the best road near the given position
  pos = pos or self.pos
  local n1, n2, dist = map.findClosestRoad(pos)
  if not n1 then
    return
  else
    local mapNodes = map.getMap().nodes

    local p1, p2 = mapNodes[n1].pos, mapNodes[n2].pos
    local nDir = (p2 - p1):normalized()
    local link = mapNodes[n1].links[n2] or mapNodes[n2].links[n1]
    if link and link.oneWay then -- if the road is one way, match the direction of the road
      if n1 ~= link.inNode then
        n1, n2 = n2, n1
        p1, p2 = p2, p1
        nDir:setScaled(-1)
      end
    else -- otherwise, match the direction according to the side of the road
      local dir = vec3(self.dir)
      if dir:squaredLength() == 0 then
        dir = vec3(nDir)
        dir:setScaled(sign2(pos:xnormOnLine(p1, p1 + nDir:cross(vecUp))))
      end
      if nDir:dot(dir) < 0 then
        n1, n2 = n2, n1
        p1, p2 = p2, p1
        nDir:setScaled(-1)
      end
    end

    local xnorm = pos:xnormOnLine(p1, p2)
    local nPos = linePointFromXnorm(p1, p2, xnorm)
    local radius = lerp(mapNodes[n1].radius, mapNodes[n2].radius, xnorm)

    return {n1 = n1, n2 = n2, dist = dist, pos = nPos, dir = nDir, radius = radius}
  end
end

function SignalInstance:getVehPlacement(vehId) -- returns vehicle placement data in relation to the signal
  local veh = be:getObjectByID(vehId)
  if not veh then return end

  local valid = false
  local vehPos, vehDir = veh:getPosition(), veh:getDirectionVector()
  -- direction vector check will fail if the vehicle is driving in reverse
  local dist = vehPos:distance(self.pos)
  local vehDot = vehDir:dot(self.dir)
  if dist <= math.max(5, self.radius) and vehDot > 0.707 then -- should also check for current road
    valid = true
  end
  local relDist = vehPos:xnormOnLine(self.pos, self.pos + self.dir) -- negative while before signal point

  return {valid = valid, dot = vehDot, dist = dist, relDist = relDist}
end

function SignalInstance:isVehAfterSignal(vehId) -- returns true if the vehicle has passed the signal point in a valid way
  local data = self:getVehPlacement(vehId)
  if not data then return false end

  local valid = false
  if data.valid and data.relDist >= 0 then
    valid = true
  end
  return valid, data.relDist
end

function SignalInstance:calcTargetPos() -- calculates the position at the end of the signal vector (and also the navgraph node)
  if not self.road then
    self.road = self:getBestRoad()
    if not self.road then return end
  end

  self.targetPos = self.targetPos or (self.pos + self.dir * self.radius)
  local road = self:getBestRoad(self.targetPos)
  self.road.n3 = road and road.n2
end

function SignalInstance:calcIntersectionPos(reset) -- calculates the intersection midpoint for the signal
  if not reset and self.targetPos then return end
  -- this only calculates while the signal system is active, so that other signal instances can be queried
  local vectors = {}
  local count = 0
  local refPos = self.pos + self.dir * math.max(3, self.radius)
  for _, instance in ipairs(instances) do
    -- intersection requirements here
    if self.sequenceId == instance.sequenceId then
      if self.pos:squaredDistance(instance.pos) <= 1600 then
        if instance.dir:dot(refPos - instance.pos) > 0 then
          vectors[instance.name] = instance.pos + instance.dir * instance.radius
          count = count + 1
        end
      end
    end
  end

  if count >= 2 then
    self.targetPos = vec3()
    for _, v in pairs(vectors) do
      self.targetPos:setAdd(v)
    end
    self.targetPos:setScaled(1 / count)

    local road = self:getBestRoad(self.targetPos) -- gets the ideal node of the intersection
    if road then
      local mapNodes = map.getMap().nodes
      if mapNodes[road.n1].pos:squaredDistance(self.targetPos) > mapNodes[road.n2].pos:squaredDistance(self.targetPos) then
        road.n1, road.n2 = road.n2, road.n1
      end
      self.road.n3 = road.n1
    end

    for k, _ in pairs(vectors) do
      instancesByName[k].targetPos = self.targetPos
      instancesByName[k].intersectionId = self.id -- uses the current instance id as the intersection id
      if instancesByName[k].road and self.road and self.road.n3 then
        instancesByName[k].road.n3 = self.road.n3
      end
    end
  end
end

function SignalInstance:getController()
  return elementsById[self.controllerId]
end

function SignalInstance:getSequence()
  return elementsById[self.sequenceId]
end

function SignalInstance:getState() -- returns the state name and the state data of the signal
  local controller = self:getController()
  local sequence = self:getSequence()
  local state = 'none'
  local stateData = controllerDefinitions.states.none

  if controller and self.active then
    local stateIdx = 1
    if self.priorityStateIndex then -- priority state index overrides sequence
      stateIdx = self.priorityStateIndex
    elseif sequence then -- sequence is optional, otherwise the default state will be used
      stateIdx = sequence.linkedControllers[controller.name] and sequence.linkedControllers[controller.name].stateIdx
    end
    if controller.states[stateIdx] then
      state = controller.states[stateIdx].state
      stateData = controller:getStateData(state)
    end
  end

  return state, stateData
end

function SignalInstance:refresh() -- updates running controllers and sequences linked to this instance
  if not loaded then return end

  self:setActive(not self.startDisabled) -- this resets and updates the expected signal state
  local sequence = self:getSequence()
  if sequence then
    local currStep = sequence.currStep
    local ignoreTimer = sequence.ignoreTimer
    sequence:setActive(not sequence.startDisabled)
    sequence:enableTimer(not ignoreTimer)
    if currStep > 0 then sequence:setStep(currStep) end -- jumps to the saved step
  end
end

function SignalInstance:setController(id) -- sets the controller to use, and refreshes the system, if applicable
  self.controllerId = id or 0
  self:refresh()
end

function SignalInstance:setSequence(id) -- sets the sequence to use, and refreshes the system, if applicable
  self.sequenceId = id or 0
  self:refresh()
end

function SignalInstance:setActive(val) -- (boolean) sets the active state of the signal
  self.active = val and true or false
  if self.active then
    if self:getController() then
      local valid = true
      if not self:getSequence() then
        valid = false
      else
        local sequence = self:getSequence()
        local controller = self:getController()
        if sequence.linkedControllers and sequence.linkedControllers[controller.name] then
          local lc = sequence.linkedControllers[controller.name]
          signalUpdates[self.name] = lc.controller.states[lc.stateIdx].state
        else
          valid = false
        end
      end

      if valid then
        self.priorityStateIndex = nil
      else
        self.priorityStateIndex = self:getController().defaultIndex or 1 -- priority state index is permanent, unless a sequence update resolves
      end

      self:calcIntersectionPos()
      self:calcTargetPos()

      local stateName, stateData = self:getState()
      signalUpdates[self.name] = stateName
      if stateData and stateData.flashingLights then
        stateData.flashingActive = true
        stateData.lightIdx = 0
        stateData.lightTime = -math.huge
      end
    end
  else
    signalUpdates[self.name] = 'none'
  end
end

function SignalInstance:setAuxiliaryData() -- sets and validates additional data
  local valid = true
  self._invalid = nil

  self.road = self:getBestRoad()
  if not self.road then
    if not self._invalid then
      log('E', logTag, 'Map node could not be set for signal instance: '..self.name)
    end
    valid = false
  end

  if not self:getController() then
    if not self._invalid then
      log('E', logTag, 'Controller is missing from signal instance: '..self.name)
    end
    valid = false
  end

  if not valid then
    self._invalid = true
    self.linkedObjects = {}
  else
    self.linkedObjects = self:getSignalObjects()
  end
end

function SignalInstance:include() -- adds the signal instance to the main data
  if not instancesByName[self.name] then
    table.insert(instances, self)
    instancesByName[self.name] = self
    elementsById[self.id] = self

    -- if controller or sequence objects directly exist within this instance, include them as well
    if self.controller and not controllersByName[self.controller.name] then
      self.controller:include()
    end
    if self.sequence and not controllersByName[self.sequence.name] then
      self.sequence:include()
    end
  end
end

function SignalInstance:exclude() -- removes the signal instance from the main data
  if instancesByName[self.name] then
    for i, instance in ipairs(instances) do
      if instance.name == self.name then
        table.remove(instances, i)
        break
      end
    end
    instancesByName[self.name] = nil
    elementsById[self.id] = nil
  end
end

function SignalInstance:onSerialize()
  local data = {
    id = self.id,
    name = self.name,
    pos = self.pos:toTable(),
    dir = self.dir:toTable(),
    radius = self.radius,
    controllerId = self.controllerId,
    sequenceId = self.sequenceId,
    useCurrentLane = self.useCurrentLane,
    startDisabled = self.startDisabled
  }

  return data
end

function SignalInstance:onDeserialized(data)
  data = data or {}

  for k, v in pairs(data) do
    self[k] = v
  end
  self.pos = vec3(self.pos)
  self.dir = vec3(self.dir)
end

function SignalController:new(data)
  local o = {}
  data = data or {}
  setmetatable(o, self)

  o.id = data.id or getNextId()
  o.name = data.name or 'controller'
  o.type = data.type or 'none'
  o.isSimple = data.isSimple and true or false
  o.defaultIndex = data.defaultIndex
  o.states = data.states or {}

  return o
end

function SignalController:applyDefinition(key) -- copies and sets the controller definition data (signal type) to the controller
  key = key or 'none'
  self.type = key
  table.clear(self.states)

  local data = controllerDefinitions.types[key]
  if data then
    self.isSimple = data.isSimple and true or false
    self.defaultIndex = data.defaultIndex
    if data.states then
      for _, state in ipairs(data.states) do
        local stateData = self:getStateData(state)
        if stateData then
          table.insert(self.states, {state = state, duration = stateData.duration})
        else
          log('E', logTag, 'Controller definition state not found: '..state)
        end
      end
    end
  else
    log('E', logTag, 'Controller definition type not found: '..key)
  end
end

function SignalController:getStateData(state) -- returns the states table
  return controllerDefinitions.states[state]
end

function SignalController:autoSetTimings(speedMetresPerSecond, intersectionLength, isPermissive) -- automatically calculate and set basic timings of the signals
  -- currently, these timing values assume the "permissive yellow" rule
  -- http://onlinepubs.trb.org/Onlinepubs/trr/1985/1027/1027-005.pdf

  for _, state in ipairs(self.data.states) do
    if state.type == 'greenTrafficLight' or state.type == 'greenFlashingTrafficLight' then
      state.duration = clamp(speedMetresPerSecond * 0.7 + intersectionLength * 0.6, 10, 40) -- approximate values based on speed and intersection size
    elseif state.name == 'yellowTrafficLight' then
      state.duration = clamp(1 + (speedMetresPerSecond - 4.167) / 3.27, 3, 7) -- extended kinematic equation (3.27 = 9.81 * 0.333)
    elseif state.name == 'redTrafficLight' or state.type == 'redYellowTrafficLight' then
      state.duration = 1
    end
  end
end

function SignalController:include() -- adds the signal controller to the main data
  if not controllersByName[self.name] then
    table.insert(controllers, self)
    instancesByName[self.name] = self
    elementsById[self.id] = self
  end
end

function SignalController:exclude() -- removes the signal controller from the main data
  if controllersByName[self.name] then
    for i, ctrl in ipairs(controllers) do
      if ctrl.name == self.name then
        table.remove(controllers, i)
        break
      end
    end
    controllersByName[self.name] = nil
    elementsById[self.id] = nil
  end
end

function SignalController:onSerialize()
  local data = {
    id = self.id,
    name = self.name,
    type = self.type,
    isSimple = self.isSimple,
    defaultIndex = self.defaultIndex,
    states = self.states
  }

  return data
end

function SignalController:onDeserialized(data)
  data = data or {}

  for k, v in pairs(data) do
    self[k] = v
  end
end

function SignalSequence:new(data)
  local o = {}
  data = data or {}
  setmetatable(o, self)

  o.id = data.id or getNextId()
  o.name = data.name or 'sequence'
  o.startTime = data.startTime or 0 -- can be negative
  o.phases = data.phases or {}
  o.customSequence = data.customSequence
  o.startDisabled = data.startDisabled and true or false
  o.ignoreTimer = data.ignoreTimer and true or false

  return o
end

function SignalSequence:createPhase(phase, idx) -- creates a new phase
  phase = phase or {}
  phase.controllerData = phase.controllerData or {}
  if idx then
    table.insert(self.phases, idx, phase)
  else
    table.insert(self.phases, phase)
  end
end

function SignalSequence:deletePhase(idx) -- removes a phase
  idx = idx or #self.phases
  if self.phases[idx] then
    table.remove(self.phases, idx)
  end
end

function SignalSequence:resolveUpdates(forceUpdate) -- updates all linked signal states and lights
  for _, lc in pairs(self.linkedControllers) do
    if lc._updated or forceUpdate then
      local stateBase = lc.controller.states[lc.stateIdx]
      for _, instance in pairs(lc.linkedSignals) do
        if instance.active then
          signalUpdates[instance.name] = stateBase.state
          instance.priorityStateIndex = nil
        end
      end
      lc._updated = nil
    end
  end
end

function SignalSequence:onSequenceUpdate() -- used internally whenever the sequence step updates
  -- processes next sequence timing
  local stepData = self.sequence[self.sequenceTimings[self.currStep]] or {}

  for _, inner in ipairs(stepData) do
    self.currPhase = inner[2]
    local lc = self.linkedControllers[inner[1]]
    if lc then
      lc.stateIdx = inner[3]
      lc._updated = true

      if not self.ignoreTimer then
        local duration = 0
        local t1 = self.sequenceTimings[self.currStep]
        local t2 = self.sequenceTimings[self.currStep + 1] or self.sequenceDuration
        duration = t2 - t1

        if self._deltaTime then
          duration = duration - self._deltaTime
        end

        local time = timer + duration
        queue:insert(time, self.name)
        self.stateTime = time

        if self.enableTestTimer then
          self.testTimer = t1
        end
      end
    end
  end

  self:resolveUpdates()
end

function SignalSequence:resetSequence() -- resets all sequence data
  self.currStep = 0
  self.currPhase = 1

  for k, lc in pairs(self.linkedControllers) do
    lc.stateIdx = lc.controller.defaultIndex or 1
    lc._updated = true
  end
  self:resolveUpdates()

  local time = self.startTime + timer
  queue:insert(time, self.name)
  self.stateTime = time
end

function SignalSequence:setStep(index) -- manual setting of sequence step
  -- loops through the sequence until the sequence timing index is reached
  index = index or 1
  if not self.sequenceTimings[index] then return end

  local currStep = self.currStep

  repeat
    self.currStep = self.currStep + 1
    if not self.sequenceTimings[self.currStep] then
      self.currStep = 1
    end

    local stepData = self.sequence[self.sequenceTimings[self.currStep]]
    for _, inner in ipairs(stepData) do
      local lc = self.linkedControllers[inner[1]]
      if lc then
        lc.stateIdx = inner[3]
        lc._updated = true
      end
    end
  until (self.currStep == index or self.currStep == currStep)

  self:onSequenceUpdate()
end

function SignalSequence:setPhase(index) -- manual setting of sequence phase
  -- loops through the phases until the phase index is reached
  index = index or 1
  if not self.phases[index] then return end

  local currStep = self.currStep
  local currPhase = self.currPhase
  if currPhase == index then
    self.currPhase = 0
  end

  repeat
    self.currStep = self.currStep + 1
    if not self.sequenceTimings[self.currStep] then
      self.currStep = 1
    end

    local stepData = self.sequence[self.sequenceTimings[self.currStep]]
    for _, inner in ipairs(stepData) do
      local lc = self.linkedControllers[inner[1]]
      if lc then
        lc.stateIdx = inner[3]
        lc._updated = true
        if currPhase ~= inner[2] then
          currPhase = inner[2]
          self.currPhase = inner[2]
        end
      end
    end
  until (self.currPhase == index or self.currStep == currStep)

  self:onSequenceUpdate()
end

function SignalSequence:advance() -- advances to next step
  self.currStep = self.currStep + 1
  if not self.sequenceTimings[self.currStep] then
    self.currStep = 1
  end

  self:onSequenceUpdate()
  self._deltaTime = nil
end

function SignalSequence:setStrictState(ctrlName, stateIdx) -- manually sets a controller state and updates all related signals (overrides auto state)
  -- for best results, use this after disabling the sequence timer; otherwise, the timer will interfere
  -- thisSequence:enableTimer(false)
  local lc = self.linkedControllers[ctrlName]
  if lc then
    stateIdx = stateIdx or lc.stateIdx
    local stateBase = lc.controller.states[stateIdx or 1]
    if stateBase then
      local stateRef = lc.controller:getStateData(stateBase.state)
      for _, instance in pairs(lc.linkedSignals) do
        instance:setLights(stateRef and stateRef.lights)
        signalUpdates[instance.name] = stateBase.state or 'none'
      end
    end
  end
end

function SignalSequence:setActive(val) -- (boolean) sets the active state of the signal sequence, and also runs setup
  self.active = val and true or false

  self.currStep = 1
  self.currPhase = 1
  self.stateTime = 0

  if self.active then
    table.clear(self.sequence)
    table.clear(self.linkedControllers)
    local totalTime = 0

    if self.customSequence then -- if custom sequence exists, use it instead of auto sequence
      self.sequence = self.customSequence
      self.sequenceTimings = tableKeysSorted(self.sequence)
      self:resetSequence()
      return
    end

    for phaseIdx, phase in ipairs(self.phases) do
      local totalTimeUpdated = false
      local phaseTime = totalTime
      for _, cd in ipairs(phase.controllerData) do
        if elementsById[cd.id] then
          local controller = elementsById[cd.id]
          -- build reference table for controllers and signal instances
          self.linkedControllers[controller.name] = {controller = controller, stateIdx = 1, linkedSignals = {}}

          for _, instance in ipairs(instances) do
            if instance.sequenceId == self.id and instance.controllerId == cd.id then
              self.linkedControllers[controller.name].linkedSignals[instance.name] = instance
            end
          end

          local stateTime = phaseTime
          for stateIdx, state in ipairs(controller.states) do
            self.sequence[stateTime] = self.sequence[stateTime] or {}
            table.insert(self.sequence[stateTime], {controller.name, phaseIdx, stateIdx})

            local duration = state.duration
            if not duration or duration < 0 then
              duration = 1e6 -- adds a non-infinite duration so that the sequence can still be sorted
            end
            stateTime = stateTime + duration
            if cd.required then
              totalTime = math.max(totalTime, stateTime) -- totalTime should be less if requirements are passed
              totalTimeUpdated = true
            end

            local stateData = controller:getStateData(state.state)
            if stateData and stateData.flashingLights then
              stateData.flashingActive = true
              stateData.lightIdx = 0
              stateData.lightTime = -math.huge
            end
          end
        end
      end

      if not totalTimeUpdated then
        totalTime = totalTime + 1e6 -- non-infinite duration
      end
    end

    self.sequenceTimings = tableKeysSorted(self.sequence) -- sequence timings table is used to order the sequence (by timestamp)
    self.sequenceDuration = totalTime
    --dump(self.sequence)
    --dump(self.sequenceTimings)

    self:resetSequence()

    if self.enableTestTimer then
      self.testTimer = 0
    end
  else
    for _, lc in pairs(self.linkedControllers) do
      for _, instance in pairs(lc.linkedSignals) do
        signalUpdates[instance.name] = 'none'
      end
    end

    table.clear(self.sequence)
    table.clear(self.sequenceTimings)
    table.clear(self.linkedControllers)
    self.sequenceDuration = 0
  end
end

function SignalSequence:enableTimer(val) -- (boolean) sets if this sequence responds to the main timer
  val = val and true or false
  self.ignoreTimer = not val
  if self.ignoreTimer and not val then -- invalidate queue
    self.stateTime = math.huge
  elseif not self.ignoreTimer and val then -- restart queue
    self:onSequenceUpdate()
  end
end

function SignalSequence:include() -- adds the signal sequence to the main data
  if not sequencesByName[self.name] then
    table.insert(sequences, self)
    sequencesByName[self.name] = self
    elementsById[self.id] = self
  end
end

function SignalSequence:exclude() -- removes the signal sequence from the main data
  if sequencesByName[self.name] then
    for i, sequence in ipairs(sequences) do
      if sequence.name == self.name then
        table.remove(sequences, i)
        break
      end
    end
    sequencesByName[self.name] = nil
    elementsById[self.id] = nil
  end
end

function SignalSequence:onSerialize()
  local data = {
    id = self.id,
    name = self.name,
    phases = self.phases,
    customSequence = self.customSequence,
    startTime = self.startTime,
    startDisabled = self.startDisabled,
    ignoreTimer = self.ignoreTimer
  }

  return data
end

function SignalSequence:onDeserialized(data)
  data = data or {}

  for k, v in pairs(data) do
    self[k] = v
  end
end

local function newInstance(data)
  return SignalInstance:new(data)
end

local function newController(data)
  return SignalController:new(data)
end

local function newSequence(data)
  return SignalSequence:new(data)
end

local function setControllerDefinitions(data) -- sets custom controller states and types (e.g. custom traffic light phase)
  if type(data) == 'table' then
    tableMerge(controllerDefinitions.states, data.states or {})
    tableMerge(controllerDefinitions.types, data.types or {})
  end
end

local function getControllerDefinitions() -- returns all controller definitions
  return controllerDefinitions
end

local function getInstances() -- returns the array of signal instances
  return instances
end

local function getMapNodeSignals() -- returns the processed dict of map nodes relating to signals
  return mapNodeSignals
end

local function getInstanceByName(name) -- returns the signal instance via the given name
  return instancesByName[name]
end

local function getControllers() -- returns the array of signal controllers
  return controllers
end

local function getControllerByName(name) -- returns the signal controller via the given name
  return controllersByName[name]
end

local function getSequences() -- returns the array of signal sequences
  return sequences
end

local function getSequenceByName(name) -- returns the signal sequence via the given name
  return sequencesByName[name]
end

local function getData() -- returns all data from this module
  return {
    instances = instances,
    controllers = controllers,
    sequences = sequences,
    loaded = loaded,
    active = active,
    timer = timer,
    nextTime = not queue:empty() and queue:peekKey() or 0
  }
end

local function resetTimer() -- resets the timer & queue, and activates the sequences
  timer = 0
  queue:clear()

  for _, sequence in ipairs(sequences) do
    sequence:setActive(not sequence.startDisabled)
  end
  for _, instance in pairs(instances) do
    if not instance._invalid then
      instance:setActive(not instance.startDisabled)
    end
  end
end

local function buildMapNodeSignals() -- creates a reference dict, linking map nodes to signal instances and states
  -- this gets sent to VLua
  table.clear(mapNodeSignals)

  for _, instance in ipairs(instances) do
    if not instance._invalid then
      local stateName, stateData = instance:getState()
      local n1, n2, n3 = instance.road.n1, instance.road.n2, instance.road.n3
      mapNodeSignals[n1] = mapNodeSignals[n1] or {}
      mapNodeSignals[n1][n2] = mapNodeSignals[n1][n2] or {}
      -- array containing one or more signal data points
      -- just in case two or more signals exist on the same road segment
      table.insert(mapNodeSignals[n1][n2], {instance = instance.name, pos = instance.pos, target = n3, useLane = instance.useCurrentLane, state = stateName, action = signalActions[stateData.action or 'none'] or 0})
      instance._innerIdx = #mapNodeSignals[n1][n2]
    end
  end
end

local function runSignals() -- finishes signal setup and activates main logic
  if instances[1] then
    for _, instance in pairs(instances) do
      instance.active = false
      instance:setAuxiliaryData()
    end

    for _, sequence in ipairs(sequences) do
      sequence.sequence = {}
      sequence.sequenceTimings = {}
      sequence.linkedControllers = {}
    end

    resetTimer()
    buildMapNodeSignals()
    table.clear(signalObjectsDict) -- optimizes memory usage by clearing this table, as it is not used during runtime
    loaded = true
    active = true
  end
end

local function setActive(val) -- sets the timer active state
  if not delayActive and not loaded then
    runSignals()
    if not loaded then
      log('W', logTag, 'Unable to change active state of signals, due to no signals data')
      return
    end
  end

  active = val and true or false
end

local function setupSignals(data) -- processes and enables the signals system
  if not be then return end
  loaded = false
  active = false

  table.clear(instancesByName)
  table.clear(controllersByName)
  table.clear(sequencesByName)
  table.clear(elementsById)

  if data then
    setupSignalObjects()

    instances = data.instances or {}
    for i, v in ipairs(instances) do
      instancesByName[instances[i].name] = instances[i]
      elementsById[instances[i].id] = instances[i]
    end
    controllers = data.controllers or {}
    for i, v in ipairs(controllers) do
      controllersByName[controllers[i].name] = controllers[i]
      elementsById[controllers[i].id] = controllers[i]
    end
    sequences = data.sequences or {}
    for i, v in ipairs(data.sequences) do
      sequencesByName[sequences[i].name] = sequences[i]
      elementsById[sequences[i].id] = sequences[i]
    end

    setActive(true)
  else
    table.clear(instances)
    table.clear(controllers)
    table.clear(sequences)
  end
end

local function resetSignals() -- clears signals
  setupSignals()
end

local function loadControllerDefinitions(filePath) -- loads default and custom controller definitions
  controllerDefinitions = jsonReadFile('settings/trafficSignals.json')
  if not controllerDefinitions then
    controllerDefinitions = {}
    log('E', logTag, 'Failed to load default signal controller definitions!')
    return
  end

  if not filePath then
    local levelDir = path.split(getMissionFilename()) or ''
    filePath = levelDir..'signalControllerDefinitions.json'
  end

  if FS:fileExists(filePath) then
    local defs = jsonReadFile(filePath)
    if defs then
      setControllerDefinitions(defs)
      log('I', logTag, 'Custom signal controller definitions applied')
    end
  end
end

local function loadSignals(filePath) -- loads signals json file from given file path or default file path
  if not filePath then -- auto load signals, if they exist
    local levelDir = path.split(getMissionFilename()) or ''
    filePath = levelDir..'signals.json'
  end

  loadControllerDefinitions() -- auto load controller definitions, if they exist

  if FS:fileExists(filePath) then
    local data = jsonReadFile(filePath)
    if data then
      data.instances = data.instances or {}
      for i, v in ipairs(data.instances) do
        local new = SignalInstance:new()
        new:onDeserialized(v)
        data.instances[i] = new
      end
      data.controllers = data.controllers or {}
      for i, v in ipairs(data.controllers) do
        local new = SignalController:new()
        new:onDeserialized(v)
        data.controllers[i] = new
      end
      data.sequences = data.sequences or {}
      for i, v in ipairs(data.sequences) do
        local new = SignalSequence:new()
        new:onDeserialized(v)
        data.sequences[i] = new
      end

      setupSignals(data)
      return true
    end
  end

  return false
end

local function onNavgraphReloaded() -- reload all signals
  if active then
    runSignals()
  end
end

local function onUpdate(dt, dtSim)
  if not loaded then return end

  if active then
    for stateName, stateDef in pairs(controllerDefinitions.states) do
      if stateDef.flashingActive and stateDef.flashingLights then -- process flashing lights
        if timer >= stateDef.lightTime then
          stateDef.lightTime = timer + stateDef.flashingInterval
          stateDef.lightIdx = stateDef.flashingLights[stateDef.lightIdx + 1] and stateDef.lightIdx + 1 or 1
          stateDef.lights = stateDef.flashingLights[stateDef.lightIdx]

          for _, instance in ipairs(instances) do
            if instance:getState() == stateName then
              instance:setLights(stateDef.lights)
            end
          end
        end
      end
    end

    for _, sequence in ipairs(sequences) do
      if sequence.active and sequence.enableTestTimer and not sequence.ignoreTimer then -- optional self timer for sequences (for debug or inspection purposes)
        sequence.testTimer = sequence.testTimer or 0
        if sequence.currStep > 0 then
          sequence.testTimer = sequence.testTimer + dtSim
        end
      end
    end

    -- whenever the timer is greater than the queue key, pops the queue and runs the sequence update (if valid)
    while not queue:empty() and queue:peekKey() <= timer do -- while loop is needed due to some timings happening at the same time
      local key, seqName = queue:pop()
      local sequence = sequencesByName[seqName]

      if sequence then
        if sequence.stateTime == key then -- key must match, otherwise ignore the signal update
          sequence._deltaTime = timer - key -- ensures accuracy
          sequence:advance()
        end
      end
    end

    timer = timer + dtSim
  end

  if next(signalUpdates) then -- runs whenever signal updates are queued (can be multiple per frame)
    local signalsData = {}

    for k, state in pairs(signalUpdates) do
      local instance = instancesByName[k]
      if instance and instance._innerIdx then
        local stateData = instance:getController():getStateData(state)
        local stateAction = stateData and stateData.action or 'none'
        if state ~= 'none' then
          instance:setLights(stateData and stateData.lights)
        else
          instance:setLights()
        end
        local n1, n2 = instance.road.n1, instance.road.n2
        local actionNum = signalActions[stateAction] or 0

        mapNodeSignals[n1][n2][instance._innerIdx].state = state -- this might be redundant
        mapNodeSignals[n1][n2][instance._innerIdx].action = actionNum
        -- changeSet format {inNode, outNode, innerIndex, actionValue}
        table.insert(signalsData, n1)
        table.insert(signalsData, n2)
        table.insert(signalsData, instance._innerIdx)
        table.insert(signalsData, actionNum)
      end
    end

    be:sendToMailbox('trafficSignalUpdates', lpack.encodeBin(signalsData))
    extensions.hook('onTrafficSignalUpdate', signalUpdates)
    table.clear(signalUpdates)
  end

  if not M.debugLevel or M.debugLevel <= 0 then return end

  for _, instance in ipairs(instances) do
    if core_camera.getPosition():squaredDistance(instance.pos) <= viewDistSq then -- checks if camera is close enough to signal
      if core_camera:getForward():dot(instance.pos - core_camera.getPosition()) > 0 then -- checks if camera is facing signal
        debugPos:set(instance.pos)
        debugPos.z = debugPos.z + 4

        local stateName, stateData = instance:getState()

        if M.debugLevel == 2 then
          if instance._invalid then
            debugDrawer:drawText(instance.pos, String(instance.name..' (ERROR)'), debugColors.red)
          else
            debugDrawer:drawText(instance.pos, String(instance.name), debugColors.black)
          end

          debugDrawer:drawSquarePrism(instance.pos, instance.pos + instance.dir * instance.radius, Point2F(0.5, instance.radius * 0.25), Point2F(0.5, 0), debugColors.green)
        end

        for _, light in ipairs(stateData.lights or {}) do
          debugDrawer:drawSphere(debugPos, 0.25, signalColors[light] or signalColors.white)
          debugPos.z = debugPos.z - 0.5
        end

        if M.debugLevel == 2 then
          debugDrawer:drawText(debugPos, String('state: '..(stateName or 'none')), debugColors.black)
        end
      end
    end
  end
end

local function onClientStartMission()
  loadSignals()
  delayActive = false
end

local function onClientEndMission()
  resetSignals()
  delayActive = true
end

local function onSerialize()
  local data = {}

  for k, e in pairs({instances = instances, controllers = controllers, sequences = sequences}) do
    data[k] = {}
    for _, v in ipairs(e) do
      table.insert(data[k], v:onSerialize())
    end
  end

  data.active = active
  data.loaded = loaded
  data.debugLevel = M.debugLevel

  return data
end

local function onDeserialized(data)
  M.debugLevel = data.debugLevel or 0
  loadControllerDefinitions()

  for _, v in ipairs(data.instances) do
    local res = SignalInstance:new()
    res:onDeserialized(v)
    res:include()
  end
  for _, v in ipairs(data.controllers) do
    local res = SignalController:new()
    res:onDeserialized(v)
    res:include()
  end
  for _, v in ipairs(data.sequences) do
    local res = SignalSequence:new()
    res:onDeserialized(v)
    res:include()
  end

  setActive(data.active)
  delayActive = false

  -- get the highest unique id
  _uid = 0
  for k, e in pairs({instances = instances, controllers = controllers, sequences = sequences}) do
    for i, v in ipairs(e) do
      if type(v.id) == 'number' then
        _uid = math.max(_uid, v.id)
      end
    end
  end
end

-- public interface
M.newSignal = newInstance
M.newController = newController
M.newSequence = newSequence

M.getSignals = getInstances
M.getSignalByName = getInstanceByName
M.getControllers = getControllers
M.getControllerByName = getControllerByName
M.getSequences = getSequences
M.getSequenceByName = getSequenceByName
M.getElementById = getElementById
M.getControllerDefinitions = getControllerDefinitions
M.getMapNodeSignals = getMapNodeSignals
M.getData = getData
M.getSignalsDict = nop

M.setupSignalObjects = setupSignalObjects
M.loadSignals = loadSignals
M.setupSignals = setupSignals
M.resetSignals = resetSignals
M.loadControllerDefinitions = loadControllerDefinitions
M.setControllerDefinitions = setControllerDefinitions
M.resetTimer = resetTimer
M.setActive = setActive

M.onNavgraphReloaded = onNavgraphReloaded
M.onUpdate = onUpdate
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M