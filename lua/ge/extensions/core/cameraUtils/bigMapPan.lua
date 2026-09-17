-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared "pan to a world position" helper for the bigmap camera modes (bigMap / bigMapOrtho).
-- It stores a target on the camera (cam.panTarget) and eases the camera position toward it.
-- NOTE: kept outside cameraModes/ on purpose - files in that folder are auto-loaded as camera constructors.

local M = {}

-- set a pan target so that the given world (ground) position becomes centered.
-- lookAtOffset is the camera->lookAt vector (camToLookAtPoint) of the calling camera mode.
function M.setTarget(cam, worldPos, lookAtOffset)
  if not worldPos then return end
  local offset = lookAtOffset or vec3(0, 0, 0)
  local z = cam.bigMapCamPosition and cam.bigMapCamPosition.z or worldPos.z
  cam.panTarget = vec3(worldPos.x - offset.x, worldPos.y - offset.y, z)
end

-- ease the camera toward its pan target; cancels the pan when the user moves the camera.
function M.update(cam, dt, userMoving)
  if not cam.panTarget then return end
  if userMoving then
    cam.panTarget = nil
    return
  end

  local pos = cam.bigMapCamPosition
  local t = clamp(dt * 6, 0, 1)
  pos.x = pos.x + (cam.panTarget.x - pos.x) * t
  pos.y = pos.y + (cam.panTarget.y - pos.y) * t

  local dx = cam.panTarget.x - pos.x
  local dy = cam.panTarget.y - pos.y
  if (dx * dx + dy * dy) < 0.01 then
    pos.x = cam.panTarget.x
    pos.y = cam.panTarget.y
    cam.panTarget = nil
  end
end

return M
