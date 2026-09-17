-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

require("utils")
local playerTags = require("ge/extensions/render/playerTags")
local M = {}

local maxPlayers = 64 -- TODO hardcoded, should be same as steering fastpath limit in t3d side

local playerCount = 1   -- last settled player count (from getAssignedPlayers)
local taggedCount = nil -- player count the current tags were built for (nil = none built)

-- returns a list of currently active vehicles, excluding autonomous traffic and parked vehicles
local function getActiveVehicles()
  local res = {}
  for _, veh in activeVehiclesIterator() do
    if not veh.isTraffic and not veh.isParked then
      table.insert(res, veh)
    end
  end
  return res
end

-- returns a list of which player is controlling each input device
-- e.g. { "keyboard": 0, "xinput0": 1, "mouse": 0 }
local lastMultiseat = false
local function getAssignedPlayers(devices, logEnabled, seatPlayers)
  -- push/pop the multiseat actionmap
  local multiseat = settings.getValue("multiseat")
  local changed = multiseat ~= lastMultiseat
  if changed then
    local o = scenetree.findObject("MultiseatActionMap")
    if o then
      if multiseat then o:setEnabled(true)
      else o:setEnabled(false) end
    else
      log("E", "", "No multiseat action map found")
    end
  end
  lastMultiseat = multiseat

  -- assign each input device to a different player (except keyboard and mouse, those go to the same player)
  local nVehicles = #getActiveVehicles()
  local nControllers = tableSize(devices) - 1 -- assume mouse goes together with keyboard
  local players = Input.getPlayerCount and Input.getPlayerCount()
  local platformManagesPlayers = players ~= nil
  if not players then
    if multiseat then
      players = math.max(1,math.min(maxPlayers, nControllers))
    else
      players = 1
    end
  end
  playerCount = players

  if logEnabled and players > 1 then log("D", "multiseat", "Settled for "..players.." players:  supported="..maxPlayers..", vehicles="..nVehicles..", devices="..nControllers.." (& mouse)") end
  local devnames = tableKeys(devices)
  table.sort(devnames)
  local lastPlayer = 0
  lastPlayer = (lastPlayer + 1) % players -- skip the first player, it will be used by keyboard and mouse anyway
  local result = {}
  for _,devname in ipairs(devnames) do
    if devname:startswith("keyboard") or devname:startswith("mouse") then
      result[devname] = 0
      if not platformManagesPlayers then
        assignPlayerToDevice(devname, 0)
      end
    else
      if platformManagesPlayers then
        result[devname] = devices[devname][4]
      else
        result[devname] = lastPlayer
        assignPlayerToDevice(devname, lastPlayer)
      end
      lastPlayer = (lastPlayer + 1) % players
    end
  end
  if logEnabled and players > 1 then log((players>1) and "I" or "D", "", "Assigned players: "..dumps(result):gsub("\n", ""):gsub("  ", " ")) end

  -- re-seat all players in vehicles when requested
  local potentialSeatChanges = changed or multiseat -- skip re-seating players when there's no chance they'll end in a different car
  if potentialSeatChanges and seatPlayers then
    -- locate all usable vehicles
    local usedVehicles = {}
    for _, vehicle in ipairs(getActiveVehicles()) do
      usedVehicles[vehicle:getID()] = 0
    end
    -- count amount of seats used on each vehicle
    for player=0, players-1 do
      local veh = getPlayerVehicle(player)
      if veh then
        local id = veh:getId()
        usedVehicles[id] = usedVehicles[id] + 1
      end
    end
    -- assign players on foot to vehicles (favour the least occupied vehicles)
    for player=0, maxPlayers-1 do
      if player > (multiseat and players-1 or 0) then
        be:exitVehicle(player)
      else
        local veh = getPlayerVehicle(player)
        if not veh then -- player has no vehicle, is on foot
          -- locate least occupied vehicle
          local leastUsedId = nil
          local leastUsedN = math.huge
          for id,n in pairs(usedVehicles) do
            if n < leastUsedN then
              leastUsedId = id
              leastUsedN = n
            end
          end
          -- seat this player in the vehicle we found
          if leastUsedId then
            local vehicle = getObjectByID(leastUsedId)
            be:enterVehicle(player, vehicle)
            -- update vehicle occupation counters
            usedVehicles[leastUsedId] = usedVehicles[leastUsedId] + 1
          end
        end
      end
    end
  end
  return result
end

local function enterNextVehicle(player, step)
  step = step or 0
  local curVehicle = getPlayerVehicle(player)
  local curId = curVehicle and curVehicle:getID()
  local vehicles = getActiveVehicles()
  if player ~= 0 then
    table.insert(vehicles, false) -- allow multiseat players/controllers to not be assigned any vehicle, aka 'false'
  end
  local curIndex = #vehicles
  for index, vehicle in ipairs(vehicles) do
    local id = vehicle and vehicle:getID()
    if curId == id then
      curIndex = index
      break
    end
  end
  local nextIndex = (curIndex) % #vehicles + 1
  local nextVehicle = vehicles[nextIndex]
  if nextVehicle then
    be:enterVehicle(player, nextVehicle)
  else
    be:exitVehicle(player)
  end
end

local function rebuildTags()
  local tags = {}
  for i = 0, playerCount - 1 do
    tags[#tags + 1] = {player = i, label = core_locales.contextTranslate("ui.multiseat.playerTag", {number = i + 1}), color = playerTags.color(i + 1, playerCount)}
  end
  playerTags.rebuild(tags)
  taggedCount = playerCount
end

local function onUpdate()
  if extensions.isExtensionLoaded("render_splitScreen") then taggedCount = nil; return end -- split-screen owns the tags
  if not (settings.getValue("multiseat") and settings.getValue("multiseatTags") and playerCount > 1) then
    if taggedCount then playerTags.destroy(); taggedCount = nil end
    return
  end
  if taggedCount ~= playerCount then rebuildTags() end
  playerTags.updatePositions()
end

M.getAssignedPlayers = getAssignedPlayers
M.enterNextVehicle = enterNextVehicle
M.onUpdate = onUpdate
M.onLanguageChanged = function() taggedCount = nil end
M.onExtensionUnloaded = function() playerTags.reset(); taggedCount = nil end
M.onSerialize = function() playerTags.reset(); taggedCount = nil end

return M
