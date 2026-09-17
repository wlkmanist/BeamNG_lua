-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local phraseGapMsBounds = {
  min = -200,
  max = 200,
}

M.cornerGapMs = phraseGapMsBounds
M.phraseGapMs = phraseGapMsBounds
M.linkWordGapMs = phraseGapMsBounds

M.pacenoteGapMs = {
  min = -100,
  max = 400,
}

local function clampMs(value, bounds)
  local ms = tonumber(value) or 0
  ms = math.floor(ms + 0.5)
  return math.max(bounds.min, math.min(ms, bounds.max))
end

function M.clampCornerGapMs(value)
  return clampMs(value, M.cornerGapMs)
end

function M.clampPhraseGapMs(value)
  return clampMs(value, M.phraseGapMs)
end

function M.clampLinkWordGapMs(value)
  return clampMs(value, M.linkWordGapMs)
end

function M.clampPacenoteGapMs(value)
  return clampMs(value, M.pacenoteGapMs)
end

return M
