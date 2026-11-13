-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Transport-network / road-editor specific rendering: junction centres, linked tips, the road ribbon wire-frame,
-- loop/join candidates and the L/R prism ribbons. Split out of render.lua because
-- only roadNetwork + heroRoadEditor use it. Composite module: draws through the leaf primitive modules and owns
-- its own scratch pool.

-----------------------------------------------------------------------------------------------------------------------
-- User settings.
local masterWireBinormalSpacing = 2 -- The spacing of the binormal lines on master wire rendering.
local ribbonRungSpacing = 12
local zRayOffset = 0.05 -- The z-offset to add to the ribbon points when raycasting to the surface below.
local ribbonCullDist = 800 -- Non-selected ribbons and junctions: wide enough to see the network around you.
local ghostCullDist = 400 -- Their ghosts: buried roads nearby; the ghost is the costly half, one call per line.

-----------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local ffi = require('ffi')
local styleCore = require('editor/toolUtilities/style')
local util = require('editor/toolUtilities/util')
local dbgDraw = require('utils/debugDraw')
local spheres = require('editor/toolUtilities/render/spheres')
local lines = require('editor/toolUtilities/render/lines')
local tris = require('editor/toolUtilities/render/tris')
local markup = require('editor/toolUtilities/render/markup')

-- Module constants.
local abs, floor, max, min, sqrt, huge = math.abs, math.floor, math.max, math.min, math.sqrt, math.huge
local style = styleCore.getStyle()

-- Module state.
local bL, bR, tL, tR, tmp1, tmp2, tmp3 = vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3()
local depthBase, depthHandle = vec3(), vec3()


-- Transport-network junction centres (green spheres + elevation like road nodes).
local function drawTransportJunctions(junctions, selectedIdx, elevScale, isGizmoActive)
  if not junctions then return end
  elevScale = elevScale or 100.0
  selectedIdx = selectedIdx or 0
  local camPos = core_camera.getPosition()
  local cullSq = ribbonCullDist * ribbonCullDist
  for i = 1, #junctions do
    local jct = junctions[i]
    local selected = i == selectedIdx
    if selected then
      spheres.drawSphereJunction(jct.pos)
      spheres.drawSphereHighlightSelected(jct.pos)
      tmp1:set(jct.pos)
      util.vertRaycast(tmp1)
      local elevation = jct.pos.z - tmp1.z
      lines.drawElevDropLine(jct.pos, tmp1, elevation, elevScale)
      if isGizmoActive and editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
        if abs(elevation) < 0.01 then elevation = 0.0 end
        markup.markupElevation(jct.pos, elevation)
      end
    elseif jct.pos:squaredDistance(camPos) < cullSq then
      spheres.drawSphereJunctionDull(jct.pos)
    end
  end
end

local function drawGhostLine(p0, p1) debugDrawer:drawLineInstance(p0, p1, 2, style.colourRibbonGhostF, false) end

-- Flare-room handle for the selected junction: the shared (cyan) bar sphere sitting out on the widest gore, a thin
-- connector line back to the hub node, and an always-on value markup. Drag it in/out to set the junction flare room.
-- Ghosted so it stays findable when buried.
local function drawJunctionFilletHandle(base, handle, value, highlight)
  dbgDraw.drawLineInstance_MinArg(base, handle, 3, style.colourBarHandle)
  drawGhostLine(base, handle)
  spheres.drawSphereBar(handle)
  spheres.drawSphereBarGhost(handle)
  if highlight then spheres.drawSphereHighlightHover(handle) end
  markup.markupPrompt(handle, string.format('Flare %.1f m', value))
end

-- Lane tiles draw without depth test, so the ground never hides them.
-- A tile from a to b reaching len along dir, filled with col. Leaves its far corners in tmp1 (by a) and tmp2 (by b).
local function drawLaneTile(a, b, dir, len, col)
  tmp1:set(a.x + dir.x * len, a.y + dir.y * len, a.z)
  tmp2:set(b.x + dir.x * len, b.y + dir.y * len, b.z)
  dbgDraw.drawTriSolid(a, b, tmp2, col, false)
  dbgDraw.drawTriSolid(tmp2, b, a, col, false)
  dbgDraw.drawTriSolid(a, tmp2, tmp1, col, false)
  dbgDraw.drawTriSolid(tmp1, tmp2, a, col, false)
end

-- The last drawn tile's outline in colF.
local function drawLaneTileEdge(a, b, colF)
  debugDrawer:drawLineInstance(a, b, 3, colF, false)
  debugDrawer:drawLineInstance(b, tmp2, 3, colF, false)
  debugDrawer:drawLineInstance(tmp2, tmp1, 3, colF, false)
  debugDrawer:drawLineInstance(tmp1, a, 3, colF, false)
end

-- One open lane's portal at a road end: a tile from a to b across the lane, reaching len along dir, green where traffic
-- leaves the road there and red where it enters. lit (hovered or swept) shows it bright and outlined.
local function drawLanePortal(a, b, dir, len, leaves, lit)
  local col
  if leaves then col = lit and style.colourPortalLeaveLit or style.colourPortalLeave
  else col = lit and style.colourPortalEnterLit or style.colourPortalEnter end
  drawLaneTile(a, b, dir, len, col)
  if lit then drawLaneTileEdge(a, b, style.colourPortalEdgeF) end
end

-- A strip of lanes from a to b across a road end, reaching len along dir: the lanes a dragged road end would join (red),
-- or the road a lane sweep would make (blue and white-edged when ok, red when not).
local function drawLanePick(a, b, dir, len, ok)
  drawLaneTile(a, b, dir, len, ok and style.colourLaneSweepOk or style.colourLanePick)
  drawLaneTileEdge(a, b, ok and style.colourPortalEdgeF or style.colourLanePickEdgeF)
end

-- Red locked road tips linked to a junction (overdraw normal node spheres).
local function drawLinkedTips(groups)
  if not groups then return end
  for gi = 1, #groups do
    local g = groups[gi]
    local nodes = g.nodes
    if nodes and #nodes >= 1 then
      if g.jctIdStart then spheres.drawSphereNodeLocked(nodes[1]) end
      if g.jctIdFinish then spheres.drawSphereNodeLocked(nodes[#nodes]) end
    end
  end
end

-- Faint no-depth copies of a spline's nodes, bar those in the optional hidden set (keyed by node index), so handles buried
-- in terrain stay findable.
local function drawNodeGhosts(spline, hidden)
  if not (spline and spline.isEnabled and not spline.isLink) then return end
  local nodes = spline.nodes
  for j = 1, #nodes do
    if not (hidden and hidden[j]) then spheres.drawSphereNodeGhost(nodes[j]) end
  end
end

-- Faint no-depth copies of each nearby junction's centre and outer edges (the asphalt outline between its arms), so
-- buried junctions still show. `rev` is the caller's build revision: while it holds, the lifted edge points come from cache.
local edgeCache = setmetatable({}, { __mode = 'k' }) -- junction -> { rev, pts }
local function drawJunctionGhosts(junctions, rev)
  local camPos = core_camera.getPosition()
  local cullSq = ghostCullDist * ghostCullDist
  for i = 1, #(junctions or {}) do
    local jct = junctions[i]
    if jct.pos:squaredDistance(camPos) < cullSq then
      spheres.drawSphereJunctionGhost(jct.pos)
      local c = edgeCache[jct]
      if not (c and rev and c.rev == rev) then
        local pts, edges, z = {}, jct.connectorEdges, jct.pos.z
        for e = 1, #(edges or {}) do
          local path = edges[e].path
          for j = 1, #(path or {}) - 1 do
            local a, b = path[j], path[j + 1]
            pts[#pts + 1] = vec3(a.x, a.y, (a.z or z) + zRayOffset)
            pts[#pts + 1] = vec3(b.x, b.y, (b.z or z) + zRayOffset)
          end
        end
        c = { rev = rev, pts = pts }
        edgeCache[jct] = c
      end
      local pts = c.pts
      for k = 1, #pts - 1, 2 do drawGhostLine(pts[k], pts[k + 1]) end
    end
  end
end

-- A flat reference ribbon's left and right extents at div j, metres out from divPoints[j] along its binormal.
-- Optional reference-line extents (TN): leftExtM / rightExtM; else symmetric half-width. A divided carriageway is pushed
-- out by its (tapered) median half, corner widening pushes each edge out per station (see
-- groupMgr.computeCurveWidenTaper), and the hard shoulder is paved road too.
local function ribbonExtentsAt(spline, j)
  local med, hsL, hsR = spline.medianHalfByDiv, spline.hardShoulderLeftByDiv, spline.hardShoulderRightByDiv
  local cwL, cwR = spline.curveWidenLeftByDiv, spline.curveWidenRightByDiv
  local o = med and (med[j] or 0) or 0
  local l = (spline.leftExtM or (spline.divWidths[j] * 0.5)) + o + (hsL and (hsL[j] or 0) or 0) + (cwL and (cwL[j] or 0) or 0)
  local r = (spline.rightExtM or (spline.divWidths[j] * 0.5)) + o + (hsR and (hsR[j] or 0) or 0) + (cwR and (cwR[j] or 0) or 0)
  return l, r
end

-- One spline's wire-frame, worked out once: its edge points at each drawn station (lifted clear of the surface), the
-- depth-tested lines (edges, a rung every ribbonRungSpacing and one capping the far end) packed as x1 y1 z1 x2 y2 z2
-- floats for a single batched draw, and a bounding circle for the distance cull.
-- If the spline exposes the ACTUAL banked mesh edges (Hero Road stores meshEdgeL/R -- the true outer top edges, carrying
-- banking + crown + shoulders + the end-cap extensions), those are traced so the ribbon lies exactly on the deck. Other
-- tools fall through to the flat reference ribbon.
local function buildWire(spline, spacing)
  local eL, eR = spline.meshEdgeL, spline.meshEdgeR
  local useMesh = eL and eR and #eL >= 2
  local divPoints, binormals = spline.divPoints, spline.binormals
  local n = useMesh and #eL or #divPoints
  if n < 2 then return nil end
  local L, R = {}, {}
  local j = 1
  while true do
    local l, r
    if useMesh then
      l, r = vec3(eL[j]), vec3(eR[j])
    else
      local p, b = divPoints[j], binormals[j]
      local le, re = ribbonExtentsAt(spline, j)
      l = vec3(p.x - b.x * le, p.y - b.y * le, p.z - b.z * le)
      r = vec3(p.x + b.x * re, p.y + b.y * re, p.z + b.z * re)
    end
    l.z, r.z = l.z + zRayOffset, r.z + zRayOffset
    L[#L + 1], R[#R + 1] = l, r
    if j == n then break end
    j = min(j + spacing, n)
  end
  local k = #L
  local rungEvery = max(1, floor(ribbonRungSpacing / spacing + 0.5))
  local rungs = {}
  for s = 1, k, rungEvery do rungs[#rungs + 1] = s end
  if rungs[#rungs] ~= k then rungs[#rungs + 1] = k end
  local nLines = 2 * (k - 1) + #rungs
  local f, o = ffi.new('float[?]', 6 * nLines), 0
  local function put(a, b)
    f[o], f[o + 1], f[o + 2], f[o + 3], f[o + 4], f[o + 5] = a.x, a.y, a.z, b.x, b.y, b.z
    o = o + 6
  end
  local x0, y0, x1, y1 = huge, huge, -huge, -huge
  for s = 1, k do
    local l, r = L[s], R[s]
    if s < k then put(l, L[s + 1]); put(r, R[s + 1]) end
    x0, y0 = min(x0, l.x, r.x), min(y0, l.y, r.y)
    x1, y1 = max(x1, l.x, r.x), max(y1, l.y, r.y)
  end
  for s = 1, #rungs do put(L[rungs[s]], R[rungs[s]]) end
  local cx, cy = (x0 + x1) * 0.5, (y0 + y1) * 0.5
  return { L = L, R = R, rungs = rungs, lines = f, nLines = nLines, cx = cx, cy = cy,
           rad = sqrt((x1 - cx) ^ 2 + (y1 - cy) ^ 2) }
end

-- A cached wire still fits its spline while the geometry version and everything that sets the edges' reach match. The
-- per-station extent arrays are rebuilt as new tables, so their identity is enough. A spline without a geometry version
-- is worked out afresh every frame.
local wireCache = setmetatable({}, { __mode = 'k' }) -- spline -> { key fields..., wire }
local function wireFits(c, spline, spacing)
  return c and spline.geomVersion ~= nil and c.ver == spline.geomVersion and c.spacing == spacing
    and c.lExt == spline.leftExtM and c.rExt == spline.rightExtM and c.med == spline.medianHalfByDiv
    and c.hsL == spline.hardShoulderLeftByDiv and c.hsR == spline.hardShoulderRightByDiv
    and c.cwL == spline.curveWidenLeftByDiv and c.cwR == spline.curveWidenRightByDiv
    and c.eL == spline.meshEdgeL
end

-- Renders the wire-frame for ribbon splines. ghosted also traces the ribbons without depth test, faintly, so the stretches
-- buried in terrain still show: the selected ribbon in full, the others by their edges only.
local function renderRibbonWireFrame(splines, selSplineIdx, binormalSpacing, ghosted)
  if not splines or #splines < 1 then
    return -- Early return if no splines.
  end

  local spacing = binormalSpacing or masterWireBinormalSpacing
  local camPos = core_camera.getPosition()
  local camX, camY = camPos.x, camPos.y
  for i = 1, #splines do
    local spline = splines[i]
    if spline.isEnabled and not spline.isLink then
      local c = wireCache[spline]
      if not wireFits(c, spline, spacing) then
        c = { ver = spline.geomVersion, spacing = spacing, lExt = spline.leftExtM, rExt = spline.rightExtM,
              med = spline.medianHalfByDiv, hsL = spline.hardShoulderLeftByDiv, hsR = spline.hardShoulderRightByDiv,
              cwL = spline.curveWidenLeftByDiv, cwR = spline.curveWidenRightByDiv, eL = spline.meshEdgeL,
              wire = buildWire(spline, spacing) }
        wireCache[spline] = c
      end
      local w = c.wire
      if w then
        local selected = i == selSplineIdx
        local d = sqrt((w.cx - camX) ^ 2 + (w.cy - camY) ^ 2) - w.rad -- to the nearest the road can reach
        if selected or d < ribbonCullDist then -- the selected road is never culled (always fully visible)
          dbgDraw.LineInstance_MinArgBatch(w.lines, w.nLines, 2, selected and style.colourLayerWire2 or style.colourLayerWire3)
          if ghosted and (selected or d < ghostCullDist) then
            local L, R = w.L, w.R
            for s = 1, #L - 1 do
              drawGhostLine(L[s], L[s + 1])
              drawGhostLine(R[s], R[s + 1])
            end
            if selected then
              local rungs = w.rungs
              for s = 1, #rungs do drawGhostLine(L[rungs[s]], R[rungs[s]]) end
            end
          end
        end
      end
    end
  end
end

-- Indicate to the user visually that a loop is possible, between start/end of the same spline.
local function renderCandidateLoop(node1, node2)
  spheres.drawSphereHighlightHover(node1)
  spheres.drawSphereHighlightHover(node2)
  lines.drawJoinLine(node1, node2) -- Draw a special line to indicate that a loop is possible.
  tmp1:setAdd2(node1, node2)
  tmp1:setScaled(0.5) -- Mid point.
  markup.markupLoop(tmp1) -- Text markup: hold CTRL + drop to form the loop.
end

-- Indicate to the user visually that a join is possible, between two separate splines. refusal: why the tool would refuse it,
-- shown instead (red ends, a still line and the reason).
local function renderCandidateJoin(node1, node2, refusal)
  tmp1:setAdd2(node1, node2)
  tmp1:setScaled(0.5) -- Mid point.
  if refusal then
    spheres.drawSphereNodeLocked(node1)
    spheres.drawSphereNodeLocked(node2)
    dbgDraw.drawLineInstance_MinArg(node1, node2, style.loopThickness, style.colourNodeLocked)
    markup.markupPrompt(tmp1, '[' .. refusal .. ']')
    return
  end
  spheres.drawSphereHighlightHover(node1)
  spheres.drawSphereHighlightHover(node2)
  lines.drawJoinLine(node1, node2) -- Draw a special line to indicate that a loop is possible.
  markup.markupJoin(tmp1) -- Text markup: hold CTRL + drop to join.
end

-- Renders the given ribbon.
-- [Ribbons are splines which are placed in L-R pairs, and have segments comprising of adjacent 8-point boxes.]
-- [They can have active surfaces (top or bottom), and closest segments.
-- They are used for dynamic audio emitter placement, for example.]
-- [ribbon - The ribbon to render.]
-- [pMouse - The current mouse position.]
-- [isSelectedRibbon - Whether the ribbon is selected, or not.]
-- [selectedNodeIdx - The index of the selected ribbon node, if it exists.]
-- [placedLeftNode - The left node position, if it has been placed by the user.]
-- [bestCursorSeg - The index of the closest segment, if it exists.]
-- [isDragging - Whether the node is being dragged, or not.]
local function handleRibbonRendering(ribbons, selectedRibbonIdx, selectedNodeIdx, placedLeftNode, hoveredRibbonIdx, bestCursorSeg, isDragging)
  local pMouse = util.mouseOnMapPos()

  -- Iterate over each ribbon, in turn.
  for i = 1, #ribbons do
    local ribbon = ribbons[i]

    -- If the user has placed a left node for a pair, then render it.
    if placedLeftNode then
      local pLeft = placedLeftNode.p
      spheres.drawSphereNode(pLeft) -- Draw the left node.
      spheres.drawSphereHighlight(pLeft) -- Highlight the left node.
      lines.drawSplineLineDull(pLeft, pMouse) -- Line from the left node to the mouse position.
    end

    -- Render the ribbon nodes.
    local nodes = ribbon.nodes
    local numNodes = #nodes
    if numNodes >= 1 then

      -- Render the ribbon nodes for all enabled ribbons, and for hovered disabled ribbons.
      local isSelectedRibbon = i == selectedRibbonIdx
      local isHoveredRibbon = i == hoveredRibbonIdx
      if ribbon.isEnabled or isHoveredRibbon then
        local sphereFn = spheres.drawSphereNodeDull
        if isSelectedRibbon or isHoveredRibbon then
          sphereFn = spheres.drawSphereNode
        end
        for j = 1, numNodes do
          sphereFn(nodes[j])
        end
      end

      -- Highlight the selected node, on the selected ribbon.
      if isSelectedRibbon and ribbon.isEnabled then
        if nodes[selectedNodeIdx] then
          spheres.drawSphereHighlightSelected(nodes[selectedNodeIdx])
        end
      end

      -- Render depth bar handles for the selected ribbon.
      if isSelectedRibbon and ribbon.isEnabled and ribbon.depths and ribbon.barPoints and #ribbon.barPoints == numNodes then
      local depths = ribbon.depths
      local barPoints = ribbon.barPoints
      local isUpRibbon = ribbon.isUpRibbon
      if isUpRibbon == nil then
        isUpRibbon = ribbon.isUpPrism
      end
        for j = 1, numNodes do
          local pNode = nodes[j]
          local depth = depths[j] or 0.0
          depthBase:set(pNode)
          if not isUpRibbon then
            depthBase.z = depthBase.z + depth
          end
          depthHandle:set(barPoints[j])
          dbgDraw.drawLineInstance_MinArg(depthBase, depthHandle, style.barThickness, style.colourBarHandle)
          spheres.drawSphereBar(depthHandle)
        end
      end

      -- Render the segments of this ribbon.
      if (ribbon.isEnabled or isHoveredRibbon) and numNodes > 3 then -- We can only render segments if there are at least four nodes.
      local isTopActive, isUpRibbon, isAmbient, isQuadAndVolume = ribbon.isTopActive, ribbon.isUpRibbon, ribbon.isAmbient, ribbon.isQuadAndVolume
      if isUpRibbon == nil then
        isUpRibbon = ribbon.isUpPrism
      end
        local isActiveSurfTop = true
        local depths, numSegs = ribbon.depths, ribbon.numSegs
        for j = 1, numSegs do
          -- Choose the appropriate styling, depending on whether a surface is active/not active, or ribbon is selected/not selected.
          local lineFn, triFn1, triFn2 = lines.drawSplineLine, tris.drawTriNotSelectedSurface, tris.drawTriNotSelectedSurface
          if not isAmbient then
            if isTopActive then
              if isUpRibbon then
                triFn1 = tris.drawTriActiveSurface -- The ribbon is directed upwards, and has the top surface active.
                isActiveSurfTop = true
              else
                triFn2 = tris.drawTriActiveSurface -- The ribbon is directed upwards, and has the bottom surface active.
                isActiveSurfTop = false
              end
            else
              if isUpRibbon then
                triFn2 = tris.drawTriActiveSurface -- The ribbon is directed downwards, and has the bottom surface active.
                isActiveSurfTop = false
              else
                triFn1 = tris.drawTriActiveSurface -- The ribbon is directed downwards, and has the top surface active.
                isActiveSurfTop = true
              end
            end
          end
          if isQuadAndVolume then
            triFn1, triFn2 = tris.drawTriActiveSurface, tris.drawTriActiveSurface -- Override # 1: 2D quad and volume ribbons with top and bottom surfaces the same.
          end
          if isSelectedRibbon and (not isDragging) and j == bestCursorSeg then
            lineFn = lines.drawActiveSegLine -- Override # 2: Highlight the closest segment in a special colour.
          end
          if (not isSelectedRibbon) and (not isHoveredRibbon) then
            lineFn, triFn1, triFn2 = lines.drawSplineLineDull, tris.drawTriNotSelectedSurface, tris.drawTriNotSelectedSurface -- Override # 3: Unselected ribbons are drawn in dull colors.
          elseif isHoveredRibbon and (not isSelectedRibbon) then
            triFn1, triFn2 = tris.drawTriPreviewSurface, tris.drawTriPreviewSurface -- Override # 4: Hovered ribbons are drawn in a special preview colour.
          end

          -- The active surface (either top or bottom).
          local twoSegIdx = j * 2
          local i1, i2, i3, i4 = twoSegIdx - 1, twoSegIdx, twoSegIdx + 1, twoSegIdx + 2
          local lB_B, lF_B, rB_B, rF_B = nodes[i1], nodes[i2], nodes[i3], nodes[i4]
          lineFn(lB_B, lF_B)
          lineFn(rB_B, rF_B)
          lineFn(lB_B, rB_B)
          lineFn(lF_B, rF_B)
          triFn1(lB_B, lF_B, rB_B)
          triFn1(lB_B, rB_B, lF_B)
          triFn1(lF_B, rF_B, rB_B)
          triFn1(lF_B, rB_B, rF_B)

          -- Cache 'active surface' markup point 1.
          if j == 1 then
            tmp1:setAdd2(lB_B, rF_B)
            tmp1:setScaled(0.5) -- Mid point.
          end

          -- The non-active surface (the other surface).
          local d1, d2, d3, d4 = depths[i1], depths[i2], depths[i3], depths[i4]
          if not isUpRibbon then
            d1, d2, d3, d4 = -d1, -d2, -d3, -d4
          end
          bL:set(lB_B)
          bL.z = bL.z - d1
          bR:set(lF_B)
          bR.z = bR.z - d2
          tL:set(rB_B)
          tL.z = tL.z - d3
          tR:set(rF_B)
          tR.z = tR.z - d4
          lineFn(bL, bR)
          lineFn(tL, tR)
          lineFn(bL, tL)
          lineFn(bR, tR)
          triFn2(bL, bR, tL)
          triFn2(bL, tL, bR)
          triFn2(bR, tR, tL)
          triFn2(bR, tL, tR)

          -- The vertical side lines.
          lineFn(lB_B, bL)
          lineFn(lF_B, bR)
          lineFn(rB_B, tL)
          lineFn(rF_B, tR)

          -- Cache 'active surface' markup point 1.
          if j == 1 then
            tmp2:setAdd2(bL, tR)
            tmp2:setScaled(0.5) -- Mid point.
          end
        end

        -- Markup the active surface/volume, if appropriate.
        if isQuadAndVolume or isAmbient then
          tmp3:setAdd2(tmp1, tmp2)
          tmp3:setScaled(0.5) -- Mid point.
          markup.markupVolume(tmp3)
        elseif isActiveSurfTop then
          markup.markupActiveSurf(tmp1)
        else
          markup.markupActiveSurf(tmp2)
        end
      end
    end
  end
end


-- Public interface.
M.drawTransportJunctions = drawTransportJunctions
M.drawJunctionFilletHandle = drawJunctionFilletHandle
M.drawLinkedTips = drawLinkedTips
M.drawLanePortal = drawLanePortal
M.drawLanePick = drawLanePick
M.renderRibbonWireFrame = renderRibbonWireFrame
M.ribbonExtentsAt = ribbonExtentsAt
M.drawNodeGhosts = drawNodeGhosts
M.drawJunctionGhosts = drawJunctionGhosts
M.renderCandidateLoop = renderCandidateLoop
M.renderCandidateJoin = renderCandidateJoin
M.renderRibbon = handleRibbonRendering

return M