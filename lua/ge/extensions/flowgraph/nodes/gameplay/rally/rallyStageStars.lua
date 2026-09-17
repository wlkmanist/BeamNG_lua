-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}

C.name = 'Rally Stage Stars'
C.description = 'Sets rally stage medals (bronze/silver/gold) on the attempt from the finish time vs the mission thresholds. Self-contained: reads attempt.data.time and the mission missionTypeData thresholds directly.'
C.color = RallyUtil.rally_flowgraph_color
C.tags = { 'rally', 'mission', 'stars' }
C.category = 'once_instant'

C.pinSchema = {
  { dir = 'in',  type = 'table', name = 'attempt', tableType = 'attemptData', description = 'Attempt data for other nodes to process', fixed = true },
  { dir = 'out', type = 'table', name = 'attempt', tableType = 'attemptData', description = 'Attempt data for other nodes to process', fixed = true },
}

function C:workOnce()
  if not self.pinIn.flow.value then return end

  local attempt = self.pinIn.attempt.value
  if not attempt then return end

  attempt.unlockedStars = attempt.unlockedStars or {}

  -- attempt.data.time is already penalty-inclusive (recovery/flip advance the stage clock).
  local t = attempt.data and attempt.data.time
  if not attempt.dnf and t and t > 0 then
    -- Time medals from the mission's authored thresholds (filled from baselineTime in the editor).
    local mtd = self.mgr.activity and self.mgr.activity.missionTypeData
    if mtd then
      if mtd.goldTime then attempt.unlockedStars.goldTime = t <= mtd.goldTime end
      if mtd.silverTime then attempt.unlockedStars.silverTime = t <= mtd.silverTime end
      if mtd.bronzeTime then attempt.unlockedStars.bronzeTime = t <= mtd.bronzeTime end
    end
  end

  self.pinOut.attempt.value = attempt
end

return _flowgraph_createNode(C)
