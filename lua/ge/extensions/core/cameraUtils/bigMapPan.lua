-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared pan/zoom helper for the bigmap camera modes (bigMap / bigMapOrtho).
-- Kept outside cameraModes/: files in that folder are auto-loaded as camera constructors.

local M = {}

-- lookAtOffset is the camera->lookAt vector (camToLookAtPoint) of the calling camera mode.
function M.setTarget(cam, worldPos, lookAtOffset)
  if not worldPos then return end
  local offset = lookAtOffset or vec3(0, 0, 0)
  local z = cam.bigMapCamPosition and cam.bigMapCamPosition.z or worldPos.z
  cam.panTarget = vec3(worldPos.x - offset.x, worldPos.y - offset.y, z)
end

-- factor: 0 = zoomed out (fovMax), 1 = zoomed in (fovMin)
function M.zoomToFactor(cam, factor)
  factor = clamp(tonumber(factor) or 0, 0, 1)
  cam.zoomTarget = lerp(cam.fovMax, cam.fovMin, factor)
end

-- Ease toward pan/zoom targets; cancels when the user moves (or zooms, for zoomTarget).
function M.update(cam, dt, userMoving)
  local t = clamp(dt * 6, 0, 1)

  if cam.zoomTarget then
    local userZooming = MoveManager.zoomIn ~= 0 or MoveManager.zoomOut ~= 0
    if userMoving or userZooming then
      cam.zoomTarget = nil
    else
      local fov = cam.manualzoom.fov + (cam.zoomTarget - cam.manualzoom.fov) * t
      if math.abs(cam.zoomTarget - fov) < 0.01 then
        fov = cam.zoomTarget
        cam.zoomTarget = nil
      end
      cam.manualzoom.fov = fov
    end
  end

  if not cam.panTarget then return end
  if userMoving then
    cam.panTarget = nil
    return
  end

  local pos = cam.bigMapCamPosition
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
