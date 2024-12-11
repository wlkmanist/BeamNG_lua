-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local re_util = require('/lua/ge/extensions/editor/rallyEditor/util')

local C = {}
local logTag = 'aipacenotes-fg'

C.name = 'AI Pacenotes Pre-Countdown'
C.description = 'Plays pre-countdown audio.'
C.color = re_util.aip_fg_color
C.tags = {'aipacenotes'}
C.category = 'once_instant'

C.pinSchema = {
    { dir = 'in', type = 'bool', name = 'useAudio', description = "If true, the pre-countdown will be played.", hardcoded = true, default = true },
}

function C:workOnce()
  if self.pinIn.useAudio.value then
    local rallyManager = gameplay_aipacenotes.getRallyManager()
    rallyManager.audioManager:enqueuePauseSecs(0.5)

    local pnName = rallyManager:getRandomStaticPacenote('firstnoteintro')
    rallyManager.audioManager:enqueueStaticPacenoteByName(pnName)

    local pacenote = gameplay_aipacenotes.getRallyManager().notebook.pacenotes.sorted[1]
    rallyManager.audioManager:enqueuePacenote(pacenote)

    pnName = rallyManager:getRandomStaticPacenote('firstnoteoutro')
    rallyManager.audioManager:enqueueStaticPacenoteByName(pnName)
  end

end

return _flowgraph_createNode(C)
