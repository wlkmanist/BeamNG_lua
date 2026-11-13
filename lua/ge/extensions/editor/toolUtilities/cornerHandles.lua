-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared in-viewport handles for engineered-geometry corners.

local M = {}

-- Module dependencies.
local rSpheres = require('editor/toolUtilities/render/spheres')
local rLines = require('editor/toolUtilities/render/lines')
local rMarkup = require('editor/toolUtilities/render/markup')
local util = require('editor/toolUtilities/util')
local style = require('editor/toolUtilities/style')

-- Module constants.
local im = ui_imgui
local min, max, abs, sqrt, exp = math.min, math.max, math.abs, math.sqrt, math.exp
local shiftKeyIdx = im.GetKeyIndex(im.Key_ModShift)
local cornerHandleVisK = 0.12   -- outward metres per metre of radius (clamped), so the knob roughly tracks the radius on screen.
local cornerHandleVisMin, cornerHandleVisMax = 3.0, 18.0
local cornerHandleGapM = 5.0    -- min world gap the knob keeps BEYOND the PI node: both ride the outward bisector, so without this they coincide at some radii and the node (which wins picking) makes the knob unpickable.
local cornerRadiusSens = 4.5    -- radius-drag feel: e^(this) is ~the radius multiply per full-screen outward drag (so ~a quarter-screen flick already ~triples/thirds it -- small drags do real work). Camera-distance normalised, so it's zoom-independent; SHIFT scales it 10x finer for fine tuning.
local moveShowM = 25.0          -- show the on-curve move grip only once the PI runs this far off its bend (a near-180 hairpin; T blows up).
local radiusCapM = 300.0        -- hard upper clamp on the design radius (matches the CONTROLS slider max).
local defaultRadiusM = 40.0     -- fallback effective radius when neither an override nor group.engRadiusM is set.
local ghostCol = style.getStyle().colourEngHelperF     -- violet tether, matching the engineered-overlay palette.
local knobCol = style.getStyle().colourEngHandle       -- corner-radius knob core (palette green).
local knobGlowCol = style.getStyle().colourEngHandleGlow -- its glow.

-- Module state.
local drag = nil


local function cornerHitTol(rayPos, target) return 0.2 * sqrt(rayPos:distance(target)) * 0.9 end -- screen-constant hit radius (matches splineInput).

-- True when the mouse ray passes through the sphere at p. intersectsRay_Sphere returns the two ray-distances (nil on a miss),
-- and a real hit is the nearer one being in front of the camera within ray range -- same test the node/rib pickers use.
local function cornerMouseOver(ray, p)
  local a, b = intersectsRay_Sphere(ray.pos, ray.dir, p, cornerHitTol(ray.pos, p))
  return a and b and min(a, b) < 10000.0
end

-- Bend apex on the actual road for interior corner i: the arc-midpoint sample the engineered builder anchors at discMap[i].
-- This stays by the road even when the PI (node) is flung far off it (a near-180 hairpin). Falls back to the node pre-build.
local function apex(g, i)
  local dm, dp = g.discMap, g.divPoints
  if dm and dp then local k = dm[i]; if k and dp[k] then return dp[k] end end
  return g.nodes[i]
end

-- Radius knob for interior node i: anchored at the bend APEX (not the PI) so it always sits by the road, offset to the OUTSIDE
-- of the bend. Returns knob pos, outward unit dir, the corner's effective radius, and the apex. nil when the node runs straight.
local function handleGeom(g, i)
  local nodes = g.nodes
  local a, b, c = nodes[i - 1], nodes[i], nodes[i + 1]
  if not (a and b and c) then return nil end
  local ix, iy = b.x - a.x, b.y - a.y
  local il = sqrt(ix * ix + iy * iy); if il < 1e-6 then return nil end; ix, iy = ix / il, iy / il
  local ox, oy = c.x - b.x, c.y - b.y
  local ol = sqrt(ox * ox + oy * oy); if ol < 1e-6 then return nil end; ox, oy = ox / ol, oy / ol
  local tx, ty = ix + ox, iy + oy
  local tl = sqrt(tx * tx + ty * ty); if tl < 1e-3 then return nil end; tx, ty = tx / tl, ty / tl
  local sgn = (ix * oy - iy * ox) >= 0 and 1 or -1 -- +1 = left/CCW turn (centre of curvature to the left of travel).
  local outx, outy = sgn * ty, sgn * -tx -- outside of the bend (away from centre of curvature), so the knob floats off the road.
  local ov = g.corners[i]
  -- Effective radius: a pinned override wins; otherwise the auto radius the engineered build actually used (published to g.cornerR),
  -- so the knob and its readout track the geometry live and a fresh grab starts from the current value instead of snapping.
  local effR = (ov and ov.radiusM) or (g.cornerR and g.cornerR[i]) or g.engRadiusM or defaultRadiusM
  local vis = min(cornerHandleVisMax, max(cornerHandleVisMin, effR * cornerHandleVisK))
  local ap = apex(g, i)
  local px, py = b.x - ap.x, b.y - ap.y
  if px * px + py * py < moveShowM * moveShowM then
    local proj = px * outx + py * outy
    if proj > 0 then vis = max(vis, proj + cornerHandleGapM) end
  end
  return vec3(ap.x + outx * vis, ap.y + outy * vis, ap.z + 0.15), outx, outy, effR
end

-- On-curve move grip for corner i (like Civil3D's midpoint grip): only when the PI runs far off its bend does a normal on-road
-- handle appear ON the apex so the corner is editable by the road instead of chasing a node tens of metres away. nil otherwise --
-- then the node is on the road and dragged directly. ap may be passed in when the caller already has the apex, to skip the lookup.
local function moveHandle(g, i, ap)
  ap = ap or apex(g, i)
  local pi = g.nodes[i]
  local dx, dy = pi.x - ap.x, pi.y - ap.y
  if dx * dx + dy * dy <= moveShowM * moveShowM then return nil end
  return vec3(ap.x, ap.y, ap.z + 0.15)
end

-- Commit an undo action for group g through the ctx's tool-specific undo/redo hooks.
local function commit(ctx, g, name, pre)
  editor.history:commitAction(name, { old = pre, new = ctx.deepCopy(g) }, ctx.undo, ctx.redo, true)
end

-- Draws the interior-corner handles (radius knob + on-curve move grip) and runs their click/drag. Returns (consumed, hovering):
-- consumed = it owns the mouse this frame (a click/drag on a handle), so the caller skips the stock node edit; hovering = a mere
-- hover over a handle (caller should mute add-node but keep running its event pass so the gizmo stays alive).
-- ctx = { selGroupIdx, selNodeIdx, setSelNode(i), minRadius(g)->number, deepCopy(g)->snap, undo, redo, ensureOverride(g,i)->ov }.
local function update(g, ctx)
  local nN = #g.nodes
  if nN < 3 then return false end

  if drag and drag.gi == ctx.selGroupIdx then -- continue an in-progress drag regardless of hover.
    local i = drag.ni
    if drag.mode == 'move' then
      if im.IsMouseDown(0) then
        local plane = util.mouseOnPlaneZ(drag.z) -- constant-Z plane: XY move preserving the node's height.
        if plane then
          local nd = g.nodes[i]
          nd.x = nd.x + (plane.x - drag.lastX); nd.y = nd.y + (plane.y - drag.lastY)
          drag.lastX, drag.lastY = plane.x, plane.y
          g.isDirty = true -- ribbon re-samples via the drag-hide path; the mesh waits for release.
          local dp = vec3(plane.x + drag.offX, plane.y + drag.offY, nd.z + 0.15) -- grip stays under the cursor.
          rLines.drawForegroundLine(apex(g, i), dp, ghostCol) -- tether the grip to the bend it drives; the road sits off elsewhere while the PI is flung out.
          rSpheres.drawSphereNode(dp)
          rSpheres.drawSphereNodeGhost(dp)
          rSpheres.drawSphereHighlightHover(dp)
          rMarkup.markupPrompt(dp, '[Drag To Move Corner]')
        end
        return true
      end
      if drag.pre then commit(ctx, g, "Move Corner", drag.pre) end
      drag = nil
      return true
    end
    if im.IsMouseDown(0) then
      local plane = util.mouseOnPlaneZ(drag.z)
      if plane then
        local proj = (plane.x - drag.nx) * drag.inx + (plane.y - drag.ny) * drag.iny
        -- Zoom-independent, radius-proportional drag: normalise the outward world move by the camera distance (so it feels the same
        -- at any zoom -- this is what fixes the far-out "wild jump"), then grow/shrink the radius MULTIPLICATIVELY (fine on hairpins,
        -- coarse on big sweeps). Re-anchor curR to the clamped value so hitting the fold floor / cap can't wind up.
        local gain = im.IsKeyDown(shiftKeyIdx) and 0.1 or 1.0 -- SHIFT = precision, integrated per-frame so toggling never jumps.
        local screenDelta = (proj - drag.lastProj) / drag.camD
        drag.lastProj = proj
        local newR = min(radiusCapM, max(ctx.minRadius(g), drag.curR * exp(screenDelta * cornerRadiusSens * gain)))
        drag.curR = newR
        ctx.ensureOverride(g, i).radiusM = newR
        g.isDirty = true -- ribbon re-samples via the drag-hide path; the mesh waits for release.
      end
      local hp, _, _, effR = handleGeom(g, i) -- keep the knob drawn (pulsing) with a live readout while the drag is held.
      if hp then
        rLines.drawForegroundLine(apex(g, i), hp, ghostCol)
        rSpheres.drawSphereCurveHandleHoverCol(hp, knobCol, knobGlowCol)
        rSpheres.drawSphereCornerHandleGhost(hp)
        rMarkup.markupPrompt(hp, string.format('[Drag To Adjust Corner Radius. Hold SHIFT For Precision]\n[Radius = %.0f m]', effR))
      end
      return true
    end
    local ov = g.corners[i]
    local newR = ov and ov.radiusM
    if drag.pre and newR and abs(newR - drag.startR) > 0.01 then commit(ctx, g, "Adjust Corner Radius", drag.pre) end
    drag = nil
    return true
  end

  local ray = getCameraMouseRay()
  if not ray then return false end

  -- Node priority: if the cursor is over a NODE, the frame belongs to the stock node editor (place / select / drag / gizmo).
  -- The handles are then purely visual, so dragging a node never turns into a handle drag and adding nodes is never blocked.
  local overNode = false
  for i = 1, nN do
    if cornerMouseOver(ray, g.nodes[i]) then overNode = true; break end
  end

  local hoverKnob, hoverMove = nil, nil
  for i = 2, nN - 1 do
    local hp, _, _, effR = handleGeom(g, i)
    if hp then
      local ap = apex(g, i)
      rLines.drawForegroundLine(ap, hp, ghostCol)
      local hit = (not overNode) and cornerMouseOver(ray, hp)
      if hit then hoverKnob = i end
      if hit then -- pulse + glow like a node under the cursor, and spell out the drag + live value like the other spline markups.
        rSpheres.drawSphereCurveHandleHoverCol(hp, knobCol, knobGlowCol)
        rMarkup.markupPrompt(hp, string.format('[Drag To Adjust Corner Radius. Hold SHIFT For Precision]\n[Radius = %.0f m]', effR))
      else
        rSpheres.drawSphereCurveHandleCol(hp, knobCol, knobGlowCol)
      end
      rSpheres.drawSphereCornerHandleGhost(hp)

      -- On-curve move grip: only when the node is flung off-road, a normal node-style handle on the apex. Reuses the apex.
      local mh = moveHandle(g, i, ap)
      if mh then
        local mhit = (not overNode) and (not hit) and cornerMouseOver(ray, mh)
        if mhit then hoverMove = i end
        rSpheres.drawSphereNode(mh)
        rSpheres.drawSphereNodeGhost(mh)
        if mhit then
          rSpheres.drawSphereHighlightHover(mh)
          rMarkup.markupPrompt(mh, '[Drag To Move Corner]')
        elseif i == ctx.selNodeIdx then
          rSpheres.drawSphereHighlightSelected(mh) -- mirror the flung-out PI node's selected pulse onto its on-curve grip.
        end
      end
    end
  end

  -- Grab the mouse ONLY on a genuine click on a handle (nodes are excluded above). Hover / idle never consumes the frame.
  if im.IsMouseClicked(0) and not editor.isAxisGizmoHovered() then
    if hoverKnob then
      local _, inx, iny, effR = handleGeom(g, hoverKnob)
      local ap = apex(g, hoverKnob)
      local plane = util.mouseOnPlaneZ(ap.z)
      local startProj = plane and ((plane.x - ap.x) * inx + (plane.y - ap.y) * iny) or 0.0
      drag = { mode = 'radius', gi = ctx.selGroupIdx, ni = hoverKnob, startR = effR, nx = ap.x, ny = ap.y, z = ap.z,
               inx = inx, iny = iny, curR = effR, camD = max(5.0, ray.pos:distance(ap)),
               lastProj = startProj, pre = ctx.deepCopy(g) }
      if ctx.setSelNode then ctx.setSelNode(hoverKnob) end -- retarget selection to the corner being tuned.
      return true
    elseif hoverMove then
      local mh = moveHandle(g, hoverMove)
      if mh then
        local pi = g.nodes[hoverMove]
        local plane = util.mouseOnPlaneZ(pi.z)
        local px, py = plane and plane.x or pi.x, plane and plane.y or pi.y
        drag = { mode = 'move', gi = ctx.selGroupIdx, ni = hoverMove, z = pi.z,
                 lastX = px, lastY = py, offX = mh.x - px, offY = mh.y - py, pre = ctx.deepCopy(g) }
        if ctx.setSelNode then ctx.setSelNode(hoverMove) end
        return true
      end
    end
  end
  -- Hovering a handle (no click): DON'T swallow the frame -- that would also skip the event pass and blink the gizmo out. Return
  -- hover-only (consumed=false, hovering=true) so the caller keeps running the event pass but mutes just the idle "click to add
  -- node" markup under the handle. Nodes still win (overNode above clears hoverKnob/hoverMove), so placement is fine.
  if hoverKnob or hoverMove then return false, true end
  return false -- truly idle / empty space: don't consume, so node placement and dragging are unaffected.
end

-- True while a corner handle drag is live (the tool uses this to engage its drag-hide / deferred-rebuild path).
local function isDragging() return drag ~= nil end

-- Group index owning the live drag (for the tool to know which road to hide), or nil.
local function draggingGroupIdx() return drag and drag.gi end


-- Public interface.
M.update = update
M.apex = apex
M.moveHandle = moveHandle
M.isDragging = isDragging
M.draggingGroupIdx = draggingGroupIdx

return M