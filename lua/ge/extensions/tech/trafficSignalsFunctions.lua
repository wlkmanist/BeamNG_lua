-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function ts()
  return core_trafficSignals
end

local function unavailable()
  return nil, 'core_trafficSignals not available'
end

local function ctrlForId(id)
  local mod = ts()
  if not mod then return end
  for _, c in ipairs(mod.getControllers()) do
    if c.id == id then return c end
  end
end

local function seqForId(id)
  local mod = ts()
  if not mod then return end
  for _, s in ipairs(mod.getSequences()) do
    if s.id == id then return s end
  end
end

local function instanceLiveRow(inst)
  local stateName, stateData = inst:getState()
  local row = {
    name = inst.name,
    state = stateName,
    controller_id = inst.controllerId,
    sequence_id = inst.sequenceId,
    pos = inst.pos:toTable(),
    dir = inst.dir:toTable(),
  }
  if stateData then
    row.action = stateData.action
  end
  return row
end

function M.listInstances()
  local mod = ts()
  if not mod then return unavailable() end
  local out = {}
  for _, inst in ipairs(mod.getSignals()) do
    if not inst._invalid then
      local stateName, stateData = inst:getState()
      local row = {
        name = inst.name,
        state = stateName,
        controller_id = inst.controllerId,
        sequence_id = inst.sequenceId,
        pos = inst.pos:toTable(),
      }
      if stateData then
        row.action = stateData.action
      end
      table.insert(out, row)
    end
  end
  return out
end

function M.getMapNodeSignals()
  local mod = ts()
  if not mod then return unavailable() end
  return mod.getMapNodeSignals()
end

function M.getInstanceState(name)
  local mod = ts()
  if not mod then return unavailable() end
  local inst = mod.getSignalByName(name)
  if not inst then
    return nil, 'signal not found: ' .. tostring(name)
  end
  return instanceLiveRow(inst)
end

function M.getEditorSignals(name)
  local mod = ts()
  if not mod then return unavailable() end
  if name then
    local inst = mod.getSignalByName(name)
    if not inst then
      return nil, 'signal not found: ' .. tostring(name)
    end
    local ctrl = ctrlForId(inst.controllerId)
    local seq = seqForId(inst.sequenceId)
    return {
      timer = mod.getTimer(),
      instance = inst:onSerialize(),
      controller = ctrl and ctrl:onSerialize() or nil,
      sequence = seq and seq:onSerialize() or nil,
    }
  end
  if not mod.onSerialize then
    return nil, 'core_trafficSignals.onSerialize not available'
  end
  local ser = mod.onSerialize()
  return {
    timer = mod.getTimer(),
    instances = ser.instances,
    controllers = ser.controllers,
    sequences = ser.sequences,
  }
end

function M.getTimingSnapshot()
  local mod = ts()
  if not mod then return unavailable() end
  local d = mod.getData()
  local editor = mod.onSerialize and mod.onSerialize() or {}
  local sequences = {}
  for _, s in ipairs(mod.getSequences()) do
    local row = s:onSerialize()
    row.active = s.active
    row.currStep = s.currStep
    row.currPhase = s.currPhase
    row.totalDuration = s.totalDuration
    table.insert(sequences, row)
  end
  local controllers = {}
  for _, c in ipairs(mod.getControllers()) do
    local row = c:onSerialize()
    row.totalDuration = c.totalDuration
    table.insert(controllers, row)
  end
  return {
    timer = mod.getTimer(),
    active = d.active,
    loaded = d.loaded,
    controllers = controllers,
    sequences = sequences,
    instances = editor.instances,
  }
end

function M.setInstanceStrictState(name, stateIndex)
  local before, err = M.getInstanceState(name)
  if not before then return nil, err end
  local mod = ts()
  local inst = mod.getSignalByName(name)
  inst:setStrictState(stateIndex)
  local after, errAfter = M.getInstanceState(name)
  if not after then return nil, errAfter end
  return {
    instance = name,
    state_index = stateIndex,
    before = before,
    after = after,
  }
end

function M.setControllerStateDuration(controllerName, stateIndex, durationSec)
  local mod = ts()
  if not mod then return unavailable() end
  local c = mod.getControllerByName(controllerName)
  if not c then
    return nil, 'controller not found: ' .. tostring(controllerName)
  end
  if not c.states or not c.states[stateIndex] then
    return nil, 'state index out of range: ' .. tostring(stateIndex)
  end
  local before = c:onSerialize()
  c.states[stateIndex].duration = durationSec
  c:calcDuration()
  for _, seq in ipairs(mod.getSequences()) do
    seq:calcDuration()
  end
  mod.resetTimer()
  return before, c:onSerialize()
end

return M
