-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Reusable tool camera: takes over the editor camera with BeamNG's script-driven 'scriptedFree', drives it each frame from
-- the viewport RMB-drag + wheel (via the interactive cameraRig), and flies smooth eased transitions to pan / orbit focuses.

local M = {}

-- Module dependencies.
local cameraRig = require('editor/toolUtilities/cameraRig')
local canvas = require('client/canvas')

-- Module constants.
local im = ui_imgui
local min, max = math.min, math.max
local FILTER_NAME = 'toolCameraZoom' -- action-filter group blocking the stock wheel-zoom while we drive
local TRANSITION_MIN_S = 1.0        -- eased fly time for a hop of no distance at all
local TRANSITION_MAX_S = 2.0        -- ...and for anything TRANSITION_FULL_M or further away
local TRANSITION_FULL_M = 400       -- travel distance earning the full fly time
local RECENTER_S = 0.5              -- eased slide time when recentring the orbit pivot on a new selection
local GROUND_SPAN = 0.5             -- pan ground sample: half-size of the averaged square, per metre of camera height (~most of the view)
local GROUND_GRID = 2               -- ...sampled on a (2*GRID+1)^2 grid

-- Module state.
local active = false           -- driving scriptedFree (true) vs the editor's own camera (false)
local filterActive = false     -- whether our wheel-zoom action filter is currently applied
local savedCamName = nil       -- the global camera that was active on takeover, restored on hand-back
local savedCamPose = nil       -- { pos, yaw, pitch, roll } of that camera on takeover, so we can fly back to it
local scratchZ = vec3()        -- reused scratch for terrain height sampling (no per-frame alloc)


-- A 2D point held inside the terrain's sampleable footprint, with a cell of slack at BOTH ends.
local function onTerrain(x, y)
  local t = core_terrain and core_terrain.getTerrain()
  local box = t and t:getWorldBox()
  if not box then return x, y end
  local lo, hi, sq = box.minExtents, box.maxExtents, t:getSquareSize()
  return min(max(x, lo.x + sq), hi.x - sq), min(max(y, lo.y + sq), hi.y - sq)
end

-- Terrain height under a 2D point, or nil if there is no answer to be had.
local function pointHeightAt(t, box, x, y)
  local cx, cy = onTerrain(x, y)
  scratchZ:set(cx, cy, 0)
  local h = t:getHeight(scratchZ)
  if not h or h < box.minExtents.z or h > box.maxExtents.z then return nil end
  return h
end

-- Terrain height at (x, y). Given the camera's height above the ground, the mean over the ground it looks down on
-- instead: a top-down camera floating over that glides across rough terrain rather than bobbing with every bump under it.
local function terrainHeightAt(x, y, above)
  local t = core_terrain and core_terrain.getTerrain()
  local box = t and t:getWorldBox()
  if not box then return nil end
  if not above then return pointHeightAt(t, box, x, y) end
  local step = above * GROUND_SPAN / GROUND_GRID
  local sum, n = 0, 0
  for i = -GROUND_GRID, GROUND_GRID do
    for j = -GROUND_GRID, GROUND_GRID do
      local h = pointHeightAt(t, box, x + i * step, y + j * step)
      if h then sum, n = sum + h, n + 1 end
    end
  end
  if n == 0 then return nil end
  -- A peak right under the camera still keeps it well clear.
  local mid = pointHeightAt(t, box, x, y)
  return mid and max(sum / n, mid - above * 0.5) or sum / n
end

-- The scriptedFree global camera instance (nil until the camera system is up).
local function scriptedFreeCam()
  return core_camera and core_camera.getGlobalCameras and core_camera.getGlobalCameras().scriptedFree
end

-- How long a fly to `pos` should take, scaled by how far the camera actually has to travel.
local function flyTime(pos, given)
  if given then return given end
  if not (core_camera and pos) then return TRANSITION_MAX_S end
  local d = pos:distance(core_camera.getPosition())
  return TRANSITION_MIN_S + (TRANSITION_MAX_S - TRANSITION_MIN_S) * min(1, d / TRANSITION_FULL_M)
end

-- Block / unblock the stock editor wheel-zoom (and speed change) so it doesn't fight our dolly/zoom while we drive.
local function setZoomBlocked(blocked)
  local af = extensions.core_input_actionFilter or core_input_actionFilter
  if not af then return end
  af.setGroup(FILTER_NAME, { 'editorCameraZoom', 'changeCameraSpeed' })
  if filterActive == blocked then return end
  af.addAction(0, FILTER_NAME, blocked)
  filterActive = blocked
end

-- Take over the editor camera.
local function takeOver()
  if active or not core_camera then return end
  savedCamName = core_camera.getActiveGlobalCameraName() or 'free'
  local curPos = vec3(core_camera.getPosition())
  local ypr = core_camera.getYawPitchRoll() -- { yawDeg, pitchDown, rollDeg } - pitchDown matches scriptedFree's +down pitch
  savedCamPose = { pos = curPos, yaw = ypr.yawDeg or 0, pitch = ypr.pitchDown or 0, roll = ypr.rollDeg or 0 }
  core_camera.setByName(0, 'scriptedFree', false, { locked = true, driveRot = true, allowLookWhenLocked = false })
  local cam = scriptedFreeCam()
  if cam then
    cam:setPosition(curPos)
    cam:setYawPitchRollDeg(savedCamPose.yaw, savedCamPose.pitch, savedCamPose.roll)
  end
  setZoomBlocked(true)
  active = true
end

-- Clear the wheel-zoom block and switch back to the remembered global camera.
local function finishHandBack()
  setZoomBlocked(false)
  if core_camera and savedCamName then core_camera.setByName(0, savedCamName, false) end
  savedCamName, savedCamPose = nil, nil
  active = false
end

-- Hand the editor camera back.
local function handBack(animate)
  if not active then return end
  local cam = scriptedFreeCam()
  if animate and cam and savedCamPose then
    cam:setTarget({ pos = vec3(savedCamPose.pos), yawDeg = savedCamPose.yaw, pitchDeg = savedCamPose.pitch,
      rollDeg = savedCamPose.roll, time = flyTime(savedCamPose.pos), ease = 'smoothstep', onDone = finishHandBack })
  else
    finishHandBack()
  end
end

local function isActive()
  return active
end

-- Fly to a top-down PAN focus over `time` s (0 = snap, nil = scaled to the distance).
local function flyPan(x, y, groundZ, height, time)
  if not active then return end
  local cam = scriptedFreeCam()
  if not cam then return end
  -- Held on the terrain here too: drive() is what normally pens the centre in, and it stands down while the camera is
  -- animating, so flying to a point off the block would land there with nothing under it.
  x, y = onTerrain(x, y)
  -- The rig floats the camera a HEIGHT-ABOVE-THE-TERRAIN-UNDER-IT (interactive drive re-samples that ground every frame).
  local gz = groundZ or terrainHeightAt(x, y)
  local aboveGround = (height and gz) and (height - gz) or nil
  if not groundZ and aboveGround and aboveGround > 0 then
    -- Seed with the same ground mean the drive floats over, so the camera doesn't drift once it lands.
    gz = terrainHeightAt(x, y, aboveGround) or gz
    aboveGround = height - gz
  end
  local pos, yaw, pitch, roll = cameraRig.focusFootprint({ x = x, y = y }, gz, aboveGround)
  cam:setTarget({ pos = vec3(pos), yawDeg = yaw, pitchDeg = pitch, rollDeg = roll,
    time = flyTime(pos, time), ease = 'smoothstep', onDone = cameraRig.settle })
end

-- Fly to an ORBIT focus framing (x,y,z) over `time` s (nil = scaled to the distance). radius (optional) sizes the dolly so the subject frames nicely; yaw /
-- pitch (optional) override the default 3/4 angle (used to approach a detail from a known outward direction). No-op unless
-- we're driving.
local function flyOrbit(x, y, z, radius, yaw, pitch, time)
  if not active then return end
  local cam = scriptedFreeCam()
  if not cam then return end
  local pos, outYaw, outPitch, outRoll = cameraRig.focusMassing({ x = x, y = y, z = z }, radius, yaw, pitch)
  cam:setTarget({ pos = vec3(pos), yawDeg = outYaw, pitchDeg = outPitch, rollDeg = outRoll,
    time = flyTime(pos, time), ease = 'smoothstep', onDone = cameraRig.settle })
end

-- Slide the orbit PIVOT onto (x,y,z) KEEPING the current yaw / pitch / dist, over a short ease. Unlike flyOrbit (a fresh 3/4
-- reframe) this preserves the viewing angle + zoom - the gentle "recentre on what I just selected" move. No-op unless we're
-- driving.
local function recenterOrbit(x, y, z, time)
  if not active then return end
  local cam = scriptedFreeCam()
  if not cam then return end
  local pos, yaw, pitch, roll = cameraRig.recenter({ x = x, y = y, z = z })
  cam:setTarget({ pos = vec3(pos), yawDeg = yaw, pitchDeg = pitch, rollDeg = roll,
    time = time or RECENTER_S, ease = 'smoothstep', onDone = cameraRig.settle })
end

-- Per-frame interactive drive: gather the viewport RMB-drag + wheel (gated so UI / a host-declared busy state don't
-- pan/orbit) and push the rig pose to scriptedFree.
local function drive(blocked)
  if not active then return end
  local cam = scriptedFreeCam()
  if not cam or cam:isAnimating() then return end
  local io = im.GetIO()
  local hovered = editor.isViewportHovered() and not io.WantCaptureMouse and not blocked
  -- RMB drives the camera; LMB stays free for the tool's own placement / selection so the two never fight.
  local dragActive = hovered and im.IsMouseDown(1)
  -- Holding RMB normally puts the editor into relative/hidden-cursor free-look, which zeroes im.MouseDelta. Force the cursor
  -- to stay visible each frame while we own the drag so MouseDelta keeps reporting (same trick cameraV2 pan uses).
  if dragActive then canvas.showCursor() end
  local dd = io.MouseDelta
  local pos, yaw, pitch, roll = cameraRig.update(io.DeltaTime, {
    dragActive = dragActive,
    dragDX = dragActive and dd.x or 0,
    dragDY = dragActive and dd.y or 0,
    wheel = (hovered and not editor.disableCameraZoom) and io.MouseWheel or 0,
    groundZAt = terrainHeightAt, -- pan floats over the mean ground in view; orbit keeps the eye above the terrain under it
    limitXY = onTerrain,         -- off the block there is no ground to float above, so the pan camera stays on it
  })
  cam:setPose(pos, yaw, pitch, roll)
end


-- Public interface.
M.takeOver = takeOver
M.handBack = handBack
M.isActive = isActive
M.flyPan = flyPan
M.flyOrbit = flyOrbit
M.recenterOrbit = recenterOrbit
M.drive = drive

return M