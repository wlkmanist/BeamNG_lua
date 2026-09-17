-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Cinematic free camera: the free fly camera with smoothing on. A second member
-- of the not-bound camera group, so the camera key cycles free <-> smoothFree.
local freeConstructor = require('core/cameraModes/free')

return function(...)
  local o = freeConstructor(...)
  o.groupOrder = 20 -- after plain free
  o:setSmoothedCam(true)
  return o
end
