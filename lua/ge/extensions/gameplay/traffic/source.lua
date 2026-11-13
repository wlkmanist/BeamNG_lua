-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This module handles changing the source (also known as focus) of the traffic manager
-- It is loaded on demand when multiple players need to interact with traffic
-- The current implementation is simple and lightweight

local M = {}

local logTag = 'trafficSource'

local sources = {} -- sources can be either vehicle ids or fixed transforms
local updateMode = 'off' -- 'off', 'default' (and more in the future)
local updateData = {}

local function resetSources()
  for _, source in ipairs(sources) do
    if source.vehId then
      local veh = getObjectByID(source.vehId)
      if veh then
        veh:setDynDataFieldbyName('trafficClearRadius', 0, '')
      end
    end
  end
  if sources[1] then
    log("I", logTag, "Reset traffic sources")
  end
  table.clear(sources)
  gameplay_traffic.setFocus() -- resets focus to default
  gameplay_traffic.setTrafficVars({enableDynamicValues = true})
end

local function addSource(mode, data)
  -- mode can be 'camera', 'vehicle', or 'custom'
  local entry = {mode = mode, auto = false}

  if mode == 'vehicle' then
    if type(data) == 'table' then
      entry.vehId = data.vehId
    else
      entry.vehId = data
    end
    if not entry.vehId or entry.vehId <= 0 or not getObjectByID(entry.vehId) then
      return false
    end
  elseif mode == 'custom' then
    if type(data) == 'table' and data.pos and data.dir then
      entry.pos = vec3(data.pos)
      entry.dirVec = vec3(data.dir)
      entry.speed = data.speed or 0
    else
      entry = nil
    end
  end

  if entry then
    table.insert(sources, entry)
    return entry
  else
    return false
  end
end

local function removeSource(index)
  if sources[index] then
    table.remove(sources, index)
    if updateData.index == index then updateData.index = 1 end
  end
end

local function getSources()
  return sources
end

local function setSourceMode(mode, options) -- sets the active source update mode
  updateMode = mode
  options = options or {}
  table.clear(updateData)
  updateData.index = 1

  if updateMode == 'default' then
    updateData.timer = 0
    updateData.interval = math.max(1, options.interval or 5)
  end
end

local function getSourceSpeed(source)
  if not source or not source.vehId then return 0 end
  local trafficVeh = gameplay_traffic.getTraffic()[source.vehId]
  if trafficVeh then return trafficVeh.speed or 0 end
  local veh = getObjectByID(source.vehId)
  return veh and veh:getVelocity():length() or 0
end

local function updateSource(index) -- updates to the next source, can be updated automatically or manually
  -- see other comments for automatic mode notes
  if not updateData.index or not sources[1] then return end
  if index then
    updateData.index = index
  else
    local startIndex = updateData.index
    repeat
      updateData.index = updateData.index + 1
      if not sources[updateData.index] then updateData.index = 1 end
      if getSourceSpeed(sources[updateData.index]) > 1 then break end
    until updateData.index == startIndex
  end

  local source = sources[updateData.index]
  if source then
    gameplay_traffic.setFocus(source.mode, source)
  else
    log("W", logTag, "No source found at index: "..updateData.index)
  end
end

local function autoAddPlayers(defaultMode) -- automatically adds all player vehicles as sources
  resetSources()

  local players = core_multiseat.getJoinedPlayers()
  if not players[2] then return end

  for i = 1, #players do
    local vehId = be:getPlayerVehicleID(players[i])
    local veh = vehId and vehId > 0 and getObjectByID(vehId) or nil
    if veh then
      addSource('vehicle', vehId)
      veh:setDynDataFieldbyName('trafficClearRadius', 0, '160')
    end
  end

  if not sources[1] then
    log("I", logTag, "No player vehicles to use as traffic sources yet")
    return
  end

  setSourceMode(defaultMode or 'default')
  log("I", logTag, "Set traffic sources for "..#sources.." / "..#players.." players")
  gameplay_traffic.setTrafficVars({enableDynamicValues = false})
end

local function hasSource(vehId)
  for _, source in ipairs(sources) do
    if source.vehId == vehId then return true end
  end
  return false
end

-- split-screen often calls autoAddPlayers before anyone is seated; pick vehicles up when they appear
local function onVehicleSwitched(oldId, newId, player)
  if not newId or newId <= 0 or hasSource(newId) then return end
  if not core_multiseat or not core_multiseat.getJoinedPlayers()[2] then return end
  autoAddPlayers()
end

local function onVehicleResetted(vehId) -- temporary, needs to be changed into something more suitable
  if updateMode == 'off' then return end
  if updateData.timer == -1 then
    local traffic = gameplay_traffic.getTraffic()
    if traffic[vehId] and traffic[vehId].isAi then
      updateData.timer = 0 -- now the timer runs until the interval, keeping source traffic vehicles active
    end
  end
end

local function onUpdate(dt, dtSim)
  if updateMode == 'off' or not sources[1] then return end

  if updateData.timer >= 0 then
    updateData.timer = updateData.timer + dtSim
    if updateData.timer >= updateData.interval then
      updateSource()
      updateData.timer = -1 -- freeze timer and await traffic vehicle teleport to reset timer
      -- consider updating source to the player with the least perceived traffic density
    end
  end
end

M.addSource = addSource
M.removeSource = removeSource
M.updateSource = updateSource
M.resetSources = resetSources
M.getSources = getSources
M.setSourceMode = setSourceMode
M.autoAddPlayers = autoAddPlayers

M.onVehicleResetted = onVehicleResetted
M.onVehicleSwitched = onVehicleSwitched
M.onUpdate = onUpdate

return M
