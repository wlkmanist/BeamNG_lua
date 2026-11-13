-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--Purpose: Maintains a fixed total length across linked beams to emulate a chain over a pulley, like used in forklifts

local M = {}
M.type = "auxiliary"

local max = math.max

local beamAId
local beamBId

local combinedStaticLength
local isActiveCoef

--we assume that the sum of the beam lengths is constant
--this means that if one beam changes length, that change needs to be reflected in the other beam
--to do that smartly, we spread the error across both beams evenly
local function update(dt)
  local beamALength = obj:getBeamLength(beamAId)
  local beamBLength = obj:getBeamLength(beamBId)
  --calculate error based on the static length
  local halfError = max(0, beamALength + beamBLength - combinedStaticLength) * 0.5 * isActiveCoef
  --apply the half error to both beams (hence ending up with the overall error again)
  obj:setBeamLength(beamAId, beamALength - halfError)
  obj:setBeamLength(beamBId, beamBLength - halfError)
end

local function updateGFX(dt)
end

local function beamBroken(id, energy)
  --if one of the beams breaks, the system cannot work anymore and we need to stop doing anything
  if isActiveCoef > 0 and (id == beamAId or id == beamBId) then
    isActiveCoef = 0
    --make sure that both beams are broken since in reality it would be a single chain/rope structure
    obj:breakBeam(beamAId)
    obj:breakBeam(beamBId)
  end
end

local function reset(jbeamData)
  isActiveCoef = 1
end

local function init(jbeamData)
  local beamTag = jbeamData.beamTag

  local beams = beamstate.tagBeamMap[beamTag]
  if not beams or #beams ~= 2 then
    log("E", "beamChain.init", "beamTag '" .. beamTag .. "' has " .. #(beams or {}) .. " beams, expected 2")
    log("E", "beamChain.init", "beamChain system will not work correctly")
    return
  end

  beamAId = beamstate.tagBeamMap[beamTag][1]
  beamBId = beamstate.tagBeamMap[beamTag][2]

  combinedStaticLength = obj:getBeamLength(beamAId) + obj:getBeamLength(beamBId)

  isActiveCoef = 1

  M.update = update
  M.updateGFX = updateGFX
end

M.init = init
M.reset = reset

M.update = nil
M.updateGFX = nil

M.beamBroken = beamBroken

return M
