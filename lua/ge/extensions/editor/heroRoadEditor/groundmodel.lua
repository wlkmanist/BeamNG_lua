-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Groundmodel paint mode for the Hero Road Editor. An overlay/edit mode (like the design heatmap) that lets the artist brush
-- physics groundmodels (dry / wet / snow / ice) onto the carriageway. Paint is stored as WORLD-SPACE stamps on the group
-- (see surfaceKit); mesh.lua rasterises them onto quads at build. This module owns: mode state, the brush input (paint on
-- drag, undoable), and the editor overlay (coloured painted cells + brush cursor + deck wireframe).
--
-- The in-game LOOK never changes (all four materials are visually identical) -- so while painting, only the overlay updates
-- (instant, reads stamps directly). The physics mesh rebuild is DEFERRED until the artist clicks Apply (see requestApply /
-- flushPending), and even then it's the light surface-only rebuild -- so a brush stroke never drives the heavy dirty pipeline.

local M = {}

-- Module dependencies.
local im = ui_imgui
local surfaceKit = require('editor/toolUtilities/surfaceKit')
local groupMgr = require('editor/heroRoadEditor/groupMgr')
local tris = require('editor/toolUtilities/render/tris')
local lines = require('editor/toolUtilities/render/lines')
local dbgDraw = require('utils/debugDraw')

-- Module constants.
local max, pi, cos, sin = math.max, math.pi, math.cos, math.sin
local castMaxM = 2000 -- ray length for the surface pick under the cursor.
local overlayLift = 0.12 -- raise the painted-cell overlay this far (m) above the deck so it clears the crown and never z-fights.
local wireLift = 0.02 -- smaller lift for the wireframe so it hugs the surface.
local wireCull2 = 90 * 90 -- deck-wireframe draw radius squared (m^2): roads can be huge, so cull hard.
local discSegs = 24 -- brush cursor disc tessellation.

-- Module state.
local active = false
local matIndex = 2 -- current palette index; default to the first non-base surface (Wet). 1 = Dry = eraser.
local brushDefault = 3.0
local brushR = brushDefault
local showWire = false
local stroking = false -- a brush stroke (mouse held) is in progress.
local strokePre = nil -- group snapshot captured at mouse-down for one undo entry per stroke.
local lastX, lastY = nil, nil -- last dab centre, for even spacing along a drag.
local pending = {} -- set (group -> true) of roads painted since the last Apply, awaiting the physics rebuild.
local applyRequested = false -- set by the Apply button; consumed next frame (rebuild off the ImGui pass, like the dirty pipeline).

-- Reused draw scratch (no per-quad allocation).
local q00, q01, q10, q11 = vec3(), vec3(), vec3(), vec3()
local dCen, dPrev, dCur, dHit = vec3(), vec3(), vec3(), vec3()


-- Accessors.
local function isActive() return active end
local function getMatIndex() return matIndex end
local function setMatIndex(i) matIndex = i end
local function getBrushRadius() return brushR end
local function setBrushRadius(r) brushR = r end
local function getBrushDefault() return brushDefault end
local function getShowWire() return showWire end
local function setShowWire(b) showWire = b and true or false end

local function setActive(b)
  active = b and true or false
  if not active then stroking = false; strokePre = nil end
end

-- Ask for the painted roads' physics to be rebuilt (Apply button). Consumed by flushPending on the next frame -- painting
-- itself only touches the overlay, so nothing rebuilds until the artist explicitly asks for it.
local function requestApply() applyRequested = true end

-- Rebuild the physics mesh of every road painted since the last Apply, then clear the queue. Runs the light surface-only path
-- (mesh + collision, no decals/furniture/terrain-paint). Called every frame from onEditorGui; a no-op unless Apply was clicked.
-- Bake / save read the stamps directly, so they're correct even if Apply was never pressed.
local function flushPending()
  if not applyRequested then return end
  applyRequested = false
  for g in pairs(pending) do groupMgr.rebuildSurfaceOnly(g); pending[g] = nil end
end

-- Remove ALL paint from the group (caller wraps the undo commit). Physics rebuild is deferred like a normal stroke.
local function clearAll(group)
  if group and group.surfaceStamps then table.clear(group.surfaceStamps); pending[group] = true end
end

-- Draw the brush cursor: a translucent sphere plus a filled disc laid on the surface at the hit point, in the current colour.
local function drawBrush(hx, hy, hz)
  local c = surfaceKit.colOf(matIndex)
  dCen:set(hx, hy, hz + overlayLift)
  dHit:set(hx, hy, hz)
  dbgDraw.drawSphere(dHit, brushR, color(c[1], c[2], c[3], 40)) -- wrapper takes a packed color() int (raw debugDrawer wants ColorF).
  local prevA = 0.0
  for k = 1, discSegs do
    local a = k / discSegs * 2 * pi
    dPrev:set(hx + brushR * cos(prevA), hy + brushR * sin(prevA), hz + overlayLift)
    dCur:set(hx + brushR * cos(a), hy + brushR * sin(a), hz + overlayLift)
    tris.drawTriCulled(dCen, dPrev, dCur, color(c[1], c[2], c[3], 70))
    prevA = a
  end
end

-- Per-frame while the mode is on: draw the brush cursor and, on LMB drag, drop evenly-spaced world-space stamps. No mesh
-- rebuild here -- the overlay shows the change instantly; the physics rebuild is queued (pending) and applied on the next Apply.
-- One undo entry per stroke. Returns true (the mode owns the mouse) whenever active.
local function updateAndPaint(group)
  if not active or not group then return false end
  local ray = getCameraMouseRay()
  local dist = castRayStatic(ray.pos, ray.dir, castMaxM)
  local hit = dist and dist < castMaxM
  local hx, hy, hz
  if hit then
    hx, hy, hz = ray.pos.x + ray.dir.x * dist, ray.pos.y + ray.dir.y * dist, ray.pos.z + ray.dir.z * dist
    drawBrush(hx, hy, hz)
  end

  local overUI = im.GetIO().WantCaptureMouse
  local step = max(0.25, brushR * 0.5) -- dab spacing along a drag.
  local step2 = step * step
  group.surfaceStamps = group.surfaceStamps or {}

  if hit and not overUI and not editor.isAxisGizmoHovered() then
    if im.IsMouseClicked(0) then
      strokePre = groupMgr.deepCopyGroup(group)
      stroking = true; lastX, lastY = nil, nil
    end
    if stroking and im.IsMouseDown(0) then
      if not lastX or ((hx - lastX) * (hx - lastX) + (hy - lastY) * (hy - lastY)) >= step2 then
        group.surfaceStamps[#group.surfaceStamps + 1] = { x = hx, y = hy, r = brushR, m = matIndex }
        lastX, lastY = hx, hy
      end
    end
  end

  if stroking and im.IsMouseReleased(0) then
    stroking = false
    pending[group] = true -- queue the physics rebuild for the next Apply (no rebuild mid-paint).
    if strokePre then
      editor.history:commitAction('Paint Groundmodel',
        { old = strokePre, new = groupMgr.deepCopyGroup(group) },
        groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
      strokePre = nil
    end
  end
  return true
end

-- Editor overlay: tint every deck cell (carriageway + shoulders) of the (post-decimation) grid so the whole drivable surface
-- reads as covered -- base/Dry faint, painted patches stronger -- plus an optional deck wireframe. Only the selected road (bounds cost).
-- Reads the SAME stamps + grid the mesh rasterises from, so it can't disagree with the physics.
local function drawOverlay(group)
  if not active or not group then return end
  local W = group.meshGrid
  if not W or #W < 2 then return end
  local m, cols = #W, #W[1]
  local camPos = core_camera.getPosition()
  local grid = surfaceKit.buildGrid(group.surfaceStamps)

  for j = 1, m - 1 do
    local Wa, Wb = W[j], W[j + 1]
    local dcx, dcy = Wa[1].x - camPos.x, Wa[1].y - camPos.y
    local near = (dcx * dcx + dcy * dcy) <= wireCull2
    for b = 1, cols - 1 do
      local p00, p01, p10, p11 = Wa[b], Wa[b + 1], Wb[b + 1], Wb[b]
      do -- tint every deck band (carriageway + shoulders) so painted patches read anywhere on the surface.
        local cx = (p00.x + p01.x + p10.x + p11.x) * 0.25
        local cy = (p00.y + p01.y + p10.y + p11.y) * 0.25
        local mi = surfaceKit.materialAt(grid, group.surfaceStamps, cx, cy)
        local c = surfaceKit.colOf(mi)
        local col = color(c[1], c[2], c[3], surfaceKit.isBase(mi) and 60 or 135)
        q00:set(p00.x, p00.y, p00.z + overlayLift); q01:set(p01.x, p01.y, p01.z + overlayLift)
        q10:set(p10.x, p10.y, p10.z + overlayLift); q11:set(p11.x, p11.y, p11.z + overlayLift)
        tris.drawTriCulled(q00, q01, q10, col); tris.drawTriCulled(q00, q10, q11, col)
      end
      if showWire and near then -- deck triangle grid (all bands), distance-culled.
        q00:set(p00.x, p00.y, p00.z + wireLift); q01:set(p01.x, p01.y, p01.z + wireLift); q11:set(p11.x, p11.y, p11.z + wireLift)
        lines.drawLineCulled(q00, q01, 1, color(20, 20, 20, 160)) -- lateral edge.
        lines.drawLineCulled(q00, q11, 1, color(20, 20, 20, 160)) -- longitudinal edge.
      end
    end
    if showWire and near then -- close the far lateral edge of the last row so the grid reads complete.
      local pa, pb = Wa[cols], Wb[cols]
      q00:set(pa.x, pa.y, pa.z + wireLift); q01:set(pb.x, pb.y, pb.z + wireLift)
      lines.drawLineCulled(q00, q01, 1, color(20, 20, 20, 160))
    end
  end
end


-- Public interface.
M.isActive = isActive
M.setActive = setActive
M.getMatIndex = getMatIndex
M.setMatIndex = setMatIndex
M.getBrushRadius = getBrushRadius
M.setBrushRadius = setBrushRadius
M.getBrushDefault = getBrushDefault
M.getShowWire = getShowWire
M.setShowWire = setShowWire
M.flushPending = flushPending
M.requestApply = requestApply
M.clearAll = clearAll
M.updateAndPaint = updateAndPaint
M.drawOverlay = drawOverlay

return M