-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--Purpose: Distributes a measured length between multiple beams

local M = {}
M.type = "auxiliary"

local segmentBeamIds = {}
local sensorBeamId
local segmentBeamLookup
local segmentBeamCount
local invSegmentBeamCount
local sensorBeamLengthMultiplier

local isActiveCoef

--we measure the overall length via the sensor beam and then distribute it evenly across the segment beams
local function updateGFX(dt)
  local sensorBeamLength = obj:getBeamLength(sensorBeamId)
  local segmentBeamLength = sensorBeamLength * invSegmentBeamCount * sensorBeamLengthMultiplier

  for i = 1, segmentBeamCount do
    obj:setBeamLength(segmentBeamIds[i], segmentBeamLength)
  end
end

local function beamBroken(id, energy)
  --if one of the beams breaks, the system cannot work anymore and we need to stop doing anything
  if isActiveCoef > 0 and (segmentBeamLookup[id] or id == sensorBeamId) then
    isActiveCoef = 0
  end
end

local function reset(jbeamData)
  isActiveCoef = 1
end

local function init(jbeamData)
  segmentBeamIds = {}
  segmentBeamLookup = {}
  sensorBeamId = nil

  local segmentBeamTag = jbeamData.segmentBeamTag
  local sensorBeamTag = jbeamData.sensorBeamTag

  local segmentBeams = beamstate.tagBeamMap[segmentBeamTag] or {}
  local sensorBeams = beamstate.tagBeamMap[sensorBeamTag] or {}

  segmentBeamCount = 0
  for _, beam in ipairs(segmentBeams) do
    table.insert(segmentBeamIds, beam)
    segmentBeamLookup[beam] = true
    segmentBeamCount = segmentBeamCount + 1
  end

  sensorBeamId = sensorBeams[1]

  sensorBeamLengthMultiplier = jbeamData.sensorBeamLengthMultiplier or 1 --if we want to control multiple spans that are in parallel, set this to the number of spans

  if #segmentBeams <= 0 then
    log("E", "beamSegments.init", M.name .. ": beamTag '" .. segmentBeamTag .. "' has " .. #(segmentBeams or {}) .. " beams, expected > 0")
    log("E", "beamSegments.init", M.name .. ": beamSegments system will not work correctly")
    return
  end

  if not sensorBeamId then
    log("E", "beamSegments.init", M.name .. ": sensorBeamTag '" .. sensorBeamTag .. "' has no matching sensor beam")
    log("E", "beamSegments.init", M.name .. ": beamSegments system will not work correctly")
    return
  end

  invSegmentBeamCount = 1 / segmentBeamCount

  isActiveCoef = 1

  M.updateGFX = updateGFX
end

M.init = init
M.reset = reset

M.updateGFX = nil

M.beamBroken = beamBroken

return M
