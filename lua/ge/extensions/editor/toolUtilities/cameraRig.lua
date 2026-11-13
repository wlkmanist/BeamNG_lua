-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Reusable tool camera rig: interactive pan + orbit state with inertia, feeding pose (pos, yaw, pitch, roll) to a
-- script-driven camera (BeamNG's scriptedFree). Pure state + math, no engine coupling - the host tool reads input,
-- calls update(), and pushes the returned pose. Timed transitions between focuses are the host's job (scriptedFree
-- :setTarget); this module just supplies the from/to poses and the live interactive drive.

------------------------------------------------------------------------------------------------------------------

-- User constants.
local DRAG_SMOOTH = 0.5             -- live-drag delta low-pass (per frame): the APPLIED delta eases toward the raw mouse delta,
                                    -- so per-frame mouse/render pacing noise (and a single dropped warp frame) doesn't read as
                                    -- jitter while dragging. Higher = snappier (noisier), lower = smoother (laggier).
local RELEASE_WIN = 5               -- frames averaged to seed the coast velocity at release. Using the recent window (the speed
                                    -- the drag ACTUALLY had) instead of a full-history EMA stops the inertia lurching on release.
local WARP_PX = 250                 -- reject any single-frame mouse delta bigger than this - it's the engine recentring the
                                    -- hidden RMB cursor, not a real drag; letting it through would teleport + spike the inertia
local PAN_SENS = 0.0021             -- world metres panned per screen pixel, per metre of camera height (higher cam pans faster)
local PAN_DAMP = 3.5                 -- pan inertia decay (1/s): velocity *= exp(-PAN_DAMP*dt) while coasting (lower = longer glide)
local PAN_MAX_VEL = 4000             -- throw-velocity cap (m/s) so a fast flick doesn't rocket away
local PAN_HEIGHT_MIN, PAN_HEIGHT_MAX = 15, 3000 -- camera height ABOVE the terrain under the camera (m); also caps the "Go to" framing height, so a long road / big map can pull far enough out to fit.
local PAN_GROUND_SMOOTH = 6.0        -- vertical terrain-follow low-pass (1/s): eases groundZ toward the freshly sampled ground so the eye GLIDES over ridges/gullies instead of bobbing in-and-out. Higher = snappier (bobbier), lower = smoother (laggier).
local PAN_ZOOM_STEP = 0.86           -- height *= PAN_ZOOM_STEP^wheel (wheel > 0 = scroll up = zoom in)
local PAN_DEFAULT_HEIGHT = 220
-- Fixed near-top-down north-up pose. pitch 89.9 (not exactly 90) + roll 0 is deliberate: at exactly 90 the quat basis
-- hits its degenerate up-fallback (up jumps to +X, needing roll -90 to correct), and a transition that lerps roll -90->0
-- AND crosses pitch 90 snaps the view. Staying just under 90 with roll 0 keeps north straight up (up = +Y) using the
-- normal up branch the whole way, so pan<->orbit blends stay continuous. Visually identical to a true top-down.
local PAN_YAW, PAN_PITCH, PAN_ROLL = 0, 89.9, 0
-- Orbit tunables.
local ORBIT_SENS = 0.32              -- degrees rotated per screen pixel of drag
local ORBIT_DAMP = 4.5               -- orbit inertia decay (1/s) (lower = longer spin)
local ORBIT_MAX_VEL = 900            -- angular throw cap (deg/s)
local ORBIT_DIST_MIN, ORBIT_DIST_MAX = 6, 2500 -- dolly distance clamp (m)
local ORBIT_ZOOM_STEP = 0.86         -- dist *= ORBIT_ZOOM_STEP^wheel
local ORBIT_PITCH_MIN, ORBIT_PITCH_MAX = -30, 88 -- pitch is look-DOWN angle: <0 drops the eye below the pivot (mid-height) for a low hero angle looking up; stay clear of the 90 pole
local ORBIT_DEFAULT_DIST, ORBIT_DEFAULT_YAW, ORBIT_DEFAULT_PITCH = 130, 30, 32 -- pleasant 3/4 default view
local ORBIT_GROUND_MARGIN = 2.0     -- keep the orbit eye at least this far above the terrain under it (no going underground)

------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module constants.
local abs, exp, sin, cos, rad, asin, deg = math.abs, math.exp, math.sin, math.cos, math.rad, math.asin, math.deg

-- Module state.
local mode = 'pan'                   -- 'pan' (footprint) | 'orbit' (massing)
local pan = { cx = 0, cy = 0, groundZ = 0, height = PAN_DEFAULT_HEIGHT, velx = 0, vely = 0 }
local orbit = { px = 0, py = 0, pz = 0, yaw = ORBIT_DEFAULT_YAW, pitch = ORBIT_DEFAULT_PITCH, dist = ORBIT_DEFAULT_DIST, yawVel = 0, pitchVel = 0 }
local posOut = vec3()                -- reused pose position handed back each call (no per-frame allocation)
local dragSX, dragSY = 0, 0          -- smoothed live-drag delta (px), eased toward the raw mouse delta each drag frame (DRAG_SMOOTH)
local wasDrag = false                -- was the previous frame a drag? drives the one-shot drag->coast release handoff
local relEdx, relEdy, relDt = {}, {}, {} -- release window: recent smoothed deltas + their frame times, ring-buffered
local relHead, relCount = 0, 0       -- release-window head index + fill count


local function clampn(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

-- Orbit eye position for the current pivot / yaw / pitch / dist, written into posOut. Same yaw/pitch basis as
-- scriptedFree (yaw 0 -> +Y, +pitch looks down), so the returned yaw/pitch aim straight at the pivot.
local function orbitEye()
  local y, p = rad(orbit.yaw), rad(orbit.pitch)
  local cp = cos(p)
  local fx, fy, fz = sin(y) * cp, cos(y) * cp, -sin(p) -- forward: eye -> pivot
  posOut:set(orbit.px - fx * orbit.dist, orbit.py - fy * orbit.dist, orbit.pz - fz * orbit.dist)
  return posOut
end

-- Release-velocity window (B): while dragging we ring-buffer the recent SMOOTHED deltas + their frame times; on release the
-- coast is seeded from their time-average -- the speed the drag actually had in its last few frames -- rather than a
-- full-history EMA that still holds stale motion and lurches. Stores raw px deltas; each mode scales them (k / ORBIT_SENS) on read.
local function pushRelease(edx, edy, fdt)
  relHead = (relHead % RELEASE_WIN) + 1
  relEdx[relHead], relEdy[relHead], relDt[relHead] = edx, edy, fdt
  if relCount < RELEASE_WIN then relCount = relCount + 1 end
end

-- Time-averaged delta rate (px/s) over the window (0, 0 if empty).
local function releaseRate()
  if relCount == 0 then return 0, 0 end
  local sx, sy, st = 0, 0, 0
  for i = 1, relCount do sx = sx + relEdx[i]; sy = sy + relEdy[i]; st = st + relDt[i] end
  if st < 1e-4 then return 0, 0 end
  return sx / st, sy / st
end

local function clearRelease() relHead, relCount = 0, 0 end

-- Advance the interactive camera one frame and return the pose to push (pos, yawDeg, pitchDeg, rollDeg). `input` is
-- { dragActive, dragDX, dragDY, wheel, groundZAt, limitXY } - screen-space drag delta in pixels and the wheel notches
-- this frame; groundZAt(x, y[, heightAbove]) -> ground z (the mean over the view when heightAbove is given);
-- limitXY(x, y) -> x, y pens the pan centre in. Pan drags
-- grab the ground (with inertia); orbit drags spin around the pivot (with inertia); the wheel zooms/dollies. pos is a
-- shared vec3 - copy it if you need to keep it.
local function update(dt, input)
  dt = dt or 0
  if dt > 0.05 then dt = 0.05 end
  input = input or {}
  local wheel = input.wheel or 0
  local pdt = (dt > 1e-4) and dt or 0.016 -- non-zero frame time for the release-velocity window

  local ddx, ddy = input.dragDX or 0, input.dragDY or 0
  local warp = (abs(ddx) > WARP_PX or abs(ddy) > WARP_PX) -- a single implausible delta = the hidden RMB cursor being recentred
  local dragActive = input.dragActive

  -- A/C: low-pass the LIVE drag delta so per-frame mouse/render pacing noise doesn't read as jitter; on a rejected warp frame
  -- carry the last smoothed delta forward (no 1-frame stall) instead of snapping to zero. Reset between drags so a new drag
  -- doesn't inherit stale motion.
  if dragActive then
    if not warp then
      dragSX = dragSX + (ddx - dragSX) * DRAG_SMOOTH
      dragSY = dragSY + (ddy - dragSY) * DRAG_SMOOTH
    end
    pushRelease(dragSX, dragSY, pdt)
  else
    dragSX, dragSY = 0, 0
  end
  -- B: seed the coast from the recent window exactly once, on the drag->coast transition.
  local justReleased = wasDrag and not dragActive
  wasDrag = dragActive

  if mode == 'pan' then
    if wheel ~= 0 then pan.height = clampn(pan.height * (PAN_ZOOM_STEP ^ wheel), PAN_HEIGHT_MIN, PAN_HEIGHT_MAX) end
    local k = pan.height * PAN_SENS
    if dragActive then
      -- Grab-the-ground (smoothed delta): cursor right -> centre moves west; cursor down -> centre moves north (screen up is +Y north).
      pan.cx, pan.cy = pan.cx - dragSX * k, pan.cy + dragSY * k
    else
      if justReleased then -- start the coast at the ACTUAL release speed (windowed), so it doesn't lurch into inertia.
        local rx, ry = releaseRate()
        pan.velx = clampn(-rx * k, -PAN_MAX_VEL, PAN_MAX_VEL)
        pan.vely = clampn( ry * k, -PAN_MAX_VEL, PAN_MAX_VEL)
        clearRelease()
      end
      pan.cx, pan.cy = pan.cx + pan.velx * dt, pan.cy + pan.vely * dt
      local decay = exp(-PAN_DAMP * dt)
      pan.velx, pan.vely = pan.velx * decay, pan.vely * decay
      if abs(pan.velx) < 1e-3 then pan.velx = 0 end
      if abs(pan.vely) < 1e-3 then pan.vely = 0 end
    end
    -- Held to whatever ground the host will vouch for. A coast into the wall is stopped there rather than left pushing.
    if input.limitXY then
      local lx, ly = input.limitXY(pan.cx, pan.cy)
      if lx ~= pan.cx then pan.velx = 0 end
      if ly ~= pan.cy then pan.vely = 0 end
      pan.cx, pan.cy = lx, ly
    end
    -- Re-sample the ground in view (the sampler averages over it, given the height) so 'height' stays metres above the
    -- CURRENT ground. A sampler that cannot answer returns nil, and the last height we trusted is a far better guess than
    -- anything we could invent.
    if input.groundZAt then
      local gz = input.groundZAt(pan.cx, pan.cy, pan.height)
      if gz then pan.groundZ = pan.groundZ + (gz - pan.groundZ) * (1.0 - exp(-PAN_GROUND_SMOOTH * dt)) end
    end
    posOut:set(pan.cx, pan.cy, pan.groundZ + pan.height)
    return posOut, PAN_YAW, PAN_PITCH, PAN_ROLL
  end

  -- orbit
  if wheel ~= 0 then orbit.dist = clampn(orbit.dist * (ORBIT_ZOOM_STEP ^ wheel), ORBIT_DIST_MIN, ORBIT_DIST_MAX) end
  if dragActive then
    orbit.yaw = orbit.yaw + dragSX * ORBIT_SENS -- drag right turns the view right around the pivot (turntable feel)
    orbit.pitch = clampn(orbit.pitch + dragSY * ORBIT_SENS, ORBIT_PITCH_MIN, ORBIT_PITCH_MAX)
  else
    if justReleased then -- coast from the true release spin (windowed), not a stale EMA.
      local rx, ry = releaseRate()
      orbit.yawVel = clampn(rx * ORBIT_SENS, -ORBIT_MAX_VEL, ORBIT_MAX_VEL)
      orbit.pitchVel = clampn(ry * ORBIT_SENS, -ORBIT_MAX_VEL, ORBIT_MAX_VEL)
      clearRelease()
    end
    orbit.yaw = orbit.yaw + orbit.yawVel * dt
    orbit.pitch = clampn(orbit.pitch + orbit.pitchVel * dt, ORBIT_PITCH_MIN, ORBIT_PITCH_MAX)
    local decay = exp(-ORBIT_DAMP * dt)
    orbit.yawVel, orbit.pitchVel = orbit.yawVel * decay, orbit.pitchVel * decay
    if abs(orbit.yawVel) < 1e-2 then orbit.yawVel = 0 end
    if abs(orbit.pitchVel) < 1e-2 then orbit.pitchVel = 0 end
  end
  orbitEye()
  -- Terrain floor: a low pitch drops the eye toward (and under) the ground.
  if input.groundZAt then
    local gz = input.groundZAt(posOut.x, posOut.y)
    local floorZ = gz and (gz + ORBIT_GROUND_MARGIN)
    if floorZ and posOut.z < floorZ then
      orbit.pitch = clampn(deg(asin(clampn((floorZ - orbit.pz) / orbit.dist, -1, 1))), ORBIT_PITCH_MIN, ORBIT_PITCH_MAX)
      if orbit.pitchVel < 0 then orbit.pitchVel = 0 end
      orbitEye()
    end
  end
  return posOut, orbit.yaw, orbit.pitch, 0
end

-- Seed the PAN sub-state on the footprint origin and return its top-down target pose.
local function focusFootprint(originXY, terrainH, height)
  mode = 'pan'
  pan.cx = originXY and originXY.x or 0
  pan.cy = originXY and originXY.y or 0
  -- nil means the host could not read the ground there; keep whatever we were last floating over.
  pan.groundZ = terrainH or pan.groundZ or 0
  if height then pan.height = clampn(height, PAN_HEIGHT_MIN, PAN_HEIGHT_MAX) end
  pan.velx, pan.vely = 0, 0
  posOut:set(pan.cx, pan.cy, pan.groundZ + pan.height)
  return posOut, PAN_YAW, PAN_PITCH, PAN_ROLL
end

-- Seed the ORBIT sub-state on the building centroid and return its 3/4 target pose.
local function focusMassing(centroid, radius, yawDeg, pitchDeg)
  mode = 'orbit'
  orbit.px = centroid and centroid.x or 0
  orbit.py = centroid and centroid.y or 0
  orbit.pz = centroid and centroid.z or 0
  orbit.yaw = yawDeg or ORBIT_DEFAULT_YAW
  orbit.pitch = clampn(pitchDeg or ORBIT_DEFAULT_PITCH, ORBIT_PITCH_MIN, ORBIT_PITCH_MAX)
  orbit.dist = (radius and radius > 1) and clampn(radius * 2.4, ORBIT_DIST_MIN, ORBIT_DIST_MAX) or ORBIT_DEFAULT_DIST
  orbit.yawVel, orbit.pitchVel = 0, 0
  return orbitEye(), orbit.yaw, orbit.pitch, 0
end

-- Move the orbit PIVOT to `centroid` while KEEPING the current yaw / pitch / dist, and return the pose whose eye preserves that
-- framing (eye translates with the pivot).
local function recenter(centroid)
  mode = 'orbit'
  orbit.px = centroid and centroid.x or orbit.px
  orbit.py = centroid and centroid.y or orbit.py
  orbit.pz = centroid and centroid.z or orbit.pz
  orbit.yawVel, orbit.pitchVel = 0, 0
  return orbitEye(), orbit.yaw, orbit.pitch, 0
end

-- Kill any leftover inertia (call when a timed transition ends before interactive drive resumes, so the view doesn't
-- coast from a stale flick).
local function settle()
  pan.velx, pan.vely = 0, 0
  orbit.yawVel, orbit.pitchVel = 0, 0
  dragSX, dragSY, wasDrag = 0, 0, false
  clearRelease()
end

local function getMode() return mode end


-- Public interface.
M.update = update
M.focusFootprint = focusFootprint
M.focusMassing = focusMassing
M.recenter = recenter
M.settle = settle
M.getMode = getMode

return M