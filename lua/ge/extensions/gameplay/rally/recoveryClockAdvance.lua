-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- Flat per-reset clock penalties. A recovery costs a fixed number of seconds
-- regardless of stage length (realistic, and length-fair since a driver's reset
-- COUNT already scales with distance). Flips are free on special stages.
M.specialStageSeconds = {
  recovery = 5,
  flip = 0 -- code path kept, just adds nothing
}

M.nonSpecialStageSeconds = {
  recovery = 60,
  flip = 10
}

function M.getSpecialStageSeconds(recoveryType)
  return M.specialStageSeconds[recoveryType] or 0
end

function M.getSeconds(recoveryType, isSpecialStage)
  if isSpecialStage then
    return M.getSpecialStageSeconds(recoveryType)
  end
  return M.nonSpecialStageSeconds[recoveryType] or 0
end

return M
