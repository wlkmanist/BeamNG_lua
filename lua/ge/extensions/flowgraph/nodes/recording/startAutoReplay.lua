-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Start Auto Replay'
C.description = 'Will stop the current recording and start a new one'

C.pinSchema = {
  {dir = 'in', type = 'flow', impulse = true, name = 'startNewRec', description = 'Will stop the current recording and start a new one'},
}

C.tags = {}

function C:work()
  self.mgr.modules.missionReplay:startNewRec()
  -- Start both AI recording and replay
  if self.mgr.modules.aiRecording then
    self.mgr.modules.aiRecording:startAiRecording()
    self.mgr.modules.aiRecording:startAiReplay()
  end
end


return _flowgraph_createNode(C)
