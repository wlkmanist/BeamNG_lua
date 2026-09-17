-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Cuts recording loader - handles loading recce cuts and their transcripts
-- Cuts are waypoint markers where the co-driver made voice recordings during the recce

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local jsonlUtils = require('/lua/ge/extensions/gameplay/rally/util/jsonlUtils')
local normalizer = require('/lua/ge/extensions/gameplay/rally/util/normalizer')

local M = {}
local logTag = 'cutsRecording'

-- Load transcripts file into a lookup table indexed by cutId
local function loadTranscripts(missionDir, word_map)
  local fname = rallyUtil.transcriptsFile(missionDir)
  local transcripts = {}
  local tscCount = 0

  if FS:fileExists(fname) then
    jsonlUtils.readJsonlLines(fname, function(obj)
      if obj.cutId and obj.cutId > 0 then
        transcripts[obj.cutId] = obj
        tscCount = tscCount + 1
      end
    end)
  end

  log('I', logTag, 'loaded '..tostring(tscCount)..' transcripts')
  return transcripts
end

-- Load cuts and their associated transcripts
-- Returns: array of cut objects, or empty array if no cuts found
function M.load(missionDir)
  -- Load transcripts first
  local word_map = {} -- TODO add back word_map once freeform work is going again.
  local transcripts = loadTranscripts(missionDir, word_map)

  -- Load the cuts
  local fname = rallyUtil.cutsFile(missionDir)
  if not FS:fileExists(fname) then
    log('I', logTag, 'no cuts file found: '..fname)
    return {} -- Return empty array, not an error
  end

  local cuts = {}

  jsonlUtils.readJsonlLines(fname, function(obj)
    obj.pos = vec3(obj.pos)
    obj.quat = quat(obj.quat)

    -- Attach transcript if available
    local tsc = transcripts[obj.id]
    if tsc then
      local txt = tsc.resp.text
      if txt then
        txt = normalizer.replaceWords(word_map, txt)
      end

      obj.transcript = {
        error = tsc.resp.error,
        text = txt,
      }
    else
      obj.transcript = {}
    end

    table.insert(cuts, obj)
  end)

  log('I', logTag, 'loaded '..tostring(#cuts)..' cuts')
  return cuts
end

return M

