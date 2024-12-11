-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local re_util = require('/lua/ge/extensions/editor/rallyEditor/util')

local C = {}
local logTag = 'aipacenotes-fg'

C.name = 'AI Pacenotes Stage Finish'
C.description = 'Plays audio after crossing the finish line.'
C.color = re_util.aip_fg_color
C.tags = {'aipacenotes'}
C.category = 'once_instant'

C.pinSchema = {
    { dir = 'in', type = 'bool', name = 'useAudio', description = "If true, the finish will be played.", hardcoded = true, default = true },
}

function C:workOnce()
  if not self.pinIn.useAudio.value then return end

  local rallyManager = gameplay_aipacenotes.getRallyManager()
  rallyManager.audioManager:enqueuePauseSecs(0.75)
  local pnName = rallyManager:getRandomStaticPacenote('finish')
  rallyManager.audioManager:enqueueStaticPacenoteByName(pnName)
end

return _flowgraph_createNode(C)
