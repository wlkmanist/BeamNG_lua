-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"gameplay_drag_core", "gameplay_drag_phaseHandlers"}
local logTag = "drag_headsUpRace"

local dGeneral, dUtils
local hasActivityStarted = false

-- Auxiliary functions

local function clear()
  hasActivityStarted = false
end

-- Checks if all non-remote racers have completed their current dependency phase.
-- Returns true only when every local racer's phase is complete.
local function areDependenciesCompleted(dragData, skipRemote)
  if not dragData or not dragData.racers then return false end
  for _, r in pairs(dragData.racers) do
    if skipRemote and r.isLocalRacer == false then
      -- skip
    elseif r.isFinished or r.vehicleRemoved then
      -- skip
    elseif not r.phases or not r.phases[r.currentPhase] or not r.phases[r.currentPhase].completed then
      return false
    end
  end
  return true
end

-- Functions called from both inside and outside

local function onExtensionLoaded()
  dGeneral = gameplay_drag_core
  dUtils = gameplay_drag_phaseHandlers
  clear()
end

local function resetDragRace()
  hasActivityStarted = false
end

local function startActivity()
  local dragData = dGeneral.getData()
  if not dragData then return end
  dragData.isStarted = true
  hasActivityStarted = true

  local dials = {}
  if dragData.racers then
    for _, racer in pairs(dragData.racers) do
      table.insert(dials, { vehId = racer.vehId, dial = 0 })
    end
  end
  dUtils.setDialsData(dials)
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not hasActivityStarted then return end
  local dragData = dGeneral.getData()
  if not dragData or not dragData.racers then return end

  local isActivityFinished = true
  for _, racer in pairs(dragData.racers) do
    -- Only local racers determine activity completion in MP
    if racer.isLocalRacer ~= false and not racer.isFinished then
      isActivityFinished = false
    end
    if racer.isFinished or racer.vehicleRemoved then goto continue end
    local phase = racer.phases and racer.phases[racer.currentPhase]
    if not phase then goto continue end
    -- Remote racers are network-driven; skip local physics
    if racer.isLocalRacer == false then goto continue end

    dUtils.updateRacer(racer)
    local phaseFn = phase.name and dUtils[phase.name] or nil
    if type(phaseFn) ~= "function" then
      log('E', logTag, string.format("Unknown drag phase handler '%s' for vehId=%s", tostring(phase.name), tostring(racer.vehId)))
      goto continue
    end
    phaseFn(phase, racer, dtSim)
    if phase.completed and not phase.dependency then
      dUtils.changeRacerPhase(racer)
    end
    ::continue::
  end

  if isActivityFinished then
    dragData.isCompleted = true
    hasActivityStarted = false
    return
  end

  -- Phase dependency advancement differs between SP, MP host, and MP client.
  -- In MP, stage->countdown is handled by checkTimerDrift (waits for all racers via network).
  local drag = dGeneral.getDragGamemode and dGeneral.getDragGamemode()
  local isMP = drag and drag.isMultiplayer and drag.isMultiplayer()
  local isHost = isMP and drag.isServerHost and drag.isServerHost()

  if isMP and not isHost then
    -- Client: phase transitions driven by host broadcast
  elseif isHost then
    -- Host: dependency check only for post-staging phases (phase > 1)
    local localRacer
    for _, r in pairs(dragData.racers) do
      if r.isLocalRacer == true then localRacer = r; break end
    end
    if localRacer and localRacer.currentPhase > 1 and areDependenciesCompleted(dragData, true) then
      dUtils.changeAllPhases()
    end
  else
    if areDependenciesCompleted(dragData, false) then
      dUtils.changeAllPhases()
    end
  end
end

--- Determines winner by best (timer + reaction) for the important timer. DQ racers sort last.
-- dragData: current drag data with racers
M.generateWinData = function(dragData)
  if not dragData or not dragData.racers then return {} end
  local winnerList = {}
  for _, racer in pairs(dragData.racers) do
    table.insert(winnerList, {
      vehId = racer.vehId,
      lane = racer.lane,
      time = dUtils.getImportantTimerValueForWin(racer, dragData),
      isPlayable = racer.isPlayable,
      disqualified = (racer.isDisqualified ~= nil and racer.isDisqualified) or racer.isDesqualified,
    })
  end
  table.sort(winnerList, function(a, b)
    if a.disqualified and b.disqualified then
      if a.isPlayable ~= b.isPlayable then
        return a.isPlayable and not b.isPlayable
      end
      local aLane = tonumber(a.lane) or math.huge
      local bLane = tonumber(b.lane) or math.huge
      if aLane ~= bLane then
        return aLane < bLane
      end
      local aVehId = tonumber(a.vehId) or math.huge
      local bVehId = tonumber(b.vehId) or math.huge
      return aVehId < bVehId
    end
    if a.disqualified then return false end
    if b.disqualified then return true end
    return a.time < b.time
  end)
  return winnerList
end

-- Interface declarations
M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.startActivity = startActivity
M.resetDragRace = resetDragRace

return M
