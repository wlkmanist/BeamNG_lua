-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared "placeable" controller for spline-based road tools: place / pick / drag / edit per-road features positioned
-- along the centreline. A tool can carry SEVERAL placeable KINDS at once (hero road: pedestrian crossings + repair-patch
-- clusters); each kind registers its own 'host' table and everything -- placement, selection, drag, handles -- is keyed by
-- kind. Self-contained interaction + geometry-picking; the caller injects everything tool-specific through the host, so this
-- module has NO dependency on any deploy-filtered tool folder and can be shared by shipped tools. The active tool registers
-- its host(s) via setHost() on activate (after reset()). State is module-level: only one road tool is active at a time and
-- each tool calls reset() (which clears the host registry too) on activate + deactivate, so nothing leaks between tools.
--
-- Required host fields:
--   kind                   -> string          (unique id for this placeable kind, e.g. 'crossing' / 'repair')
--   label                  -> string          (human noun for prompts + undo names, e.g. 'Crossing' / 'Repair Cluster')
--   getGroups()            -> group array
--   isRoad(g)              -> true if g can carry placeables (kind check)
--   itemsOf(g)             -> the per-group item array (e.g. g.crossings), or nil
--   extentOf(item)         -> number          (the item's along-road extent, used to keep it clear of the road ends)
--   frameAt(g, t01)        -> centre, p0, p1  (world frame: centre + carriageway edge endpoints; nil if not ready)
--   tForPoint(g, worldPt, extentM) -> t01     (project a world point onto the centreline, clamped clear of mouths)
--   clampT(g, t01, extentM) -> t01            (clamp a normalized position into the legal window)
--   addItem(g, t01)        -> item            (append a new placeable; nil on failure)
--   removeItem(g, idx)                        (remove the placeable at index idx)
--   deepCopy(g)            -> group snapshot  (for undo)
--   undo, redo                                (commitAction callbacks)
--   defaultDepthM          -> number          (default extent used for placement clamping)

local M = {}

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')
local util = require('editor/toolUtilities/util')
local rSpheres = require('editor/toolUtilities/render/spheres')
local rLines = require('editor/toolUtilities/render/lines')
local rMarkup = require('editor/toolUtilities/render/markup')
local style = require('editor/toolUtilities/style')

-- Module constants.
local im = ui_imgui
local min, sqrt, huge = math.min, math.sqrt, math.huge
local cols = style.getImguiCols('crystal')
local iconsSmall = im.ImVec2(24, 24)
local ghostCol = style.getStyle().colourCrossingGhostF
local handleR = 0.55
local nodeHitBaseScale, nodeHitTypeScale = 0.2, 0.9 -- Adaptive node-hit tolerance: must match toolUtilities/splineInput node hit scaling, or tips steal handle clicks at range.

-- Module state. Only one road tool is active at a time, so its host registry + all interaction state live here.
local hosts = {}              -- kind -> host table (see the required-fields header)
local kindOrder = {}          -- kinds in registration order (deterministic iteration)
local place = nil             -- kind currently in "Add" placement mode, or nil
local hoverKind = nil         -- kind of the handle under the cursor last underMouse() (lets kind-optional calls resolve)
local sel = { kind = nil, gi = nil, ci = nil }        -- selected item
local drag = nil              -- along-road drag: { kind, gi, ci, statePre, t0 }
local sliderPreEditState = nil -- depth-slider undo batching (module-level so it can't clash with the host tool's sliders)

-- Register a placeable kind's host (call from the tool's onActivate, after reset()). The host carries its own kind.
local function setHost(host)
  if hosts[host.kind] == nil then kindOrder[#kindOrder + 1] = host.kind end
  hosts[host.kind] = host
end

-- Resolve an optional kind to a concrete one: explicit > last-hovered > sole registered kind.
local function resolveKind(kind) return kind or hoverKind or kindOrder[1] end

local function adaptiveNodeHitTol(rayPos, targetPos)
  return nodeHitBaseScale * sqrt(rayPos:distance(targetPos)) * nodeHitTypeScale
end

-- Commit a group edit through a kind's undo/redo callbacks.
local function commit(host, name, pre, post)
  editor.history:commitAction(name, { old = pre, new = post }, host.undo, host.redo, true)
end

-- Placement-mode accessors (the host tool owns the Add button; it drives these). kind optional -> any / sole kind.
local function isPlaceMode(kind) if kind then return place == kind end return place ~= nil end
local function setPlaceMode(on, kind) place = on and resolveKind(kind) or nil end
local function isDragging() return drag ~= nil end
local function hasSelection(kind) if kind then return sel.kind == kind and sel.ci ~= nil end return sel.ci ~= nil end

-- Selection accessors so a host listbox can select an item (and highlight the active row).
local function select(kind, gi, ci) sel.kind, sel.gi, sel.ci = kind, gi, ci end
local function getSelection() return sel.kind, sel.gi, sel.ci end

-- Clear everything (host onActivate / onDeactivate): registry + placement mode + selection + drag.
local function reset()
  table.clear(hosts)
  table.clear(kindOrder)
  place, hoverKind, drag = nil, nil, nil
  sel.kind, sel.gi, sel.ci = nil, nil, nil
end

-- Nearest item handle under the cursor across all kinds (adaptive radius = splineInput node hits). Returns gi, ci, kind
-- (gi/ci first so a plain `g, c = underMouse()` still works for a single-kind tool). Also stashes hoverKind.
local function underMouse()
  local ray = getCameraMouseRay()
  local bestG, bestIdx, bestKind, bestDist = nil, nil, nil, 10000
  for k = 1, #kindOrder do
    local host = hosts[kindOrder[k]]
    local groups = host.getGroups()
    for gi = 1, #groups do
      local g = groups[gi]
      local items = host.itemsOf(g)
      if items and host.isRoad(g) and g.isEnabled ~= false then
        for ci = 1, #items do
          -- Handles sit at the road edges (p0/p1), off the centreline, so they don't fight the
          -- stock "insert node" hover that lives on the ribbon centre.
          local _, p0, p1 = host.frameAt(g, items[ci].t or 0.5)
          if p0 then
            for _, hp in ipairs({ p0, p1 }) do
              local tol = adaptiveNodeHitTol(ray.pos, hp)
              local a, b = intersectsRay_Sphere(ray.pos, ray.dir, hp, tol)
              local dist = a and b and min(a, b) or nil
              if dist and dist < bestDist then bestG, bestIdx, bestKind, bestDist = gi, ci, host.kind, dist end
            end
          end
        end
      end
    end
  end
  hoverKind = bestKind
  return bestG, bestIdx, bestKind
end

-- Route a click on a handle. CTRL deletes it; a plain click selects it and starts the along-road drag (so one
-- click-drag moves it). Returns 'deleted' | 'selected' | 'none'. kind optional -> the hovered / sole kind.
local function clickHandle(groups, gi, ci, ctrlDown, kind)
  kind = resolveKind(kind)
  local host = hosts[kind]
  local g = groups[gi]
  if not g or not host then return 'none' end
  local items = host.itemsOf(g)
  if ctrlDown then
    local statePre = host.deepCopy(g)
    host.removeItem(g, ci)
    commit(host, 'Remove ' .. host.label, statePre, host.deepCopy(g))
    sel.kind, sel.gi, sel.ci = nil, nil, nil
    return 'deleted'
  end
  sel.kind, sel.gi, sel.ci = kind, gi, ci
  drag = { kind = kind, gi = gi, ci = ci, statePre = host.deepCopy(g), t0 = items[ci].t }
  return 'selected'
end

-- Ghost preview + click-to-add while placement mode is active (the armed kind). Roads only. Returns true when an item
-- was added (and selects it).
local function handlePlacement(groups)
  if not place then return false end
  local host = hosts[place]
  -- Camera-ray ↔ centerline pick (geom.isMouseOverSpline), not a terrain raycast: it hits everywhere
  -- on the road, including right over the centre and on elevated sections where mouseOnMapPos misses.
  local ray = getCameraMouseRay()
  local bestG, bestPt, bestDist = nil, nil, huge
  for gi = 1, #groups do
    local g = groups[gi]
    if host.isRoad(g) and g.isEnabled ~= false and g.nodes and #g.nodes >= 2 then
      local hit, _, pt = geom.isMouseOverSpline(g)
      if hit and pt then
        local dx, dy, dz = pt.x - ray.pos.x, pt.y - ray.pos.y, pt.z - ray.pos.z
        local d = dx * dx + dy * dy + dz * dz
        if d < bestDist then bestG, bestPt, bestDist = gi, pt, d end
      end
    end
  end
  local lower = host.label:lower()
  if not bestG then
    if util.isMouseHoveringOverTerrain() then
      rMarkup.markupText(util.mouseOnMapPos(), 'hover a road to add a ' .. lower)
    end
    return false
  end
  local group = groups[bestG]
  local t01 = host.tForPoint(group, bestPt, host.defaultDepthM)
  if not t01 then return false end
  local centre, p0, p1 = host.frameAt(group, t01)
  if not centre then return false end
  rLines.drawForegroundLine(p0, p1, ghostCol)
  rSpheres.drawSphereHighlightHoverFixed(centre, handleR)
  rMarkup.markupText(centre, 'click to add a ' .. lower)
  if im.IsMouseClicked(0) and not editor.isAxisGizmoHovered() then
    local statePre = host.deepCopy(group)
    local item = host.addItem(group, t01)
    if item then
      commit(host, 'Add ' .. host.label, statePre, host.deepCopy(group))
      sel.kind, sel.gi, sel.ci = place, bestG, #host.itemsOf(group)
      return true
    end
  end
  return false
end

-- Along-road drag of the selected handle. Returns true while it owns the frame (so the host skips the stock
-- node/aux drag). Selection begins the drag so one click-drag moves it.
local function handleSelectDrag(groups)
  local d = drag
  if not d then return false end
  local host = hosts[d.kind]
  local group = groups[d.gi]
  local items = group and host and host.itemsOf(group)
  local item = items and items[d.ci]
  if not item then drag = nil return false end
  if im.IsMouseDown(0) then
    -- Camera-ray ↔ this road's centerline, ungated (huge tol): the handle sits at the road edge, so the
    -- mouse is off the centerline during the drag — take the nearest centerline point regardless.
    local hit, _, pt = geom.isMouseOverSpline(group, huge)
    if hit and pt then
      local t01 = host.tForPoint(group, pt, host.extentOf(item))
      if t01 and t01 ~= item.t then item.t = t01 group.isDirty = true end
    end
    return true
  end
  -- Released: commit only if it actually moved (a plain click just selects).
  if d.statePre and item.t ~= d.t0 then
    commit(host, 'Move ' .. host.label, d.statePre, host.deepCopy(group))
  end
  drag = nil
  return true
end

-- Handles/highlight for existing items across every kind (only for the selected road, or the road owning the selected
-- item). showSelected = the host's global selection currently IS one of these items (drives the selected-vs-hover style).
local function drawHandles(groups, selGroup, showSelected)
  for k = 1, #kindOrder do
    local kind = kindOrder[k]
    local host = hosts[kind]
    for gi = 1, #groups do
      local g = groups[gi]
      local items = host.itemsOf(g)
      if items and host.isRoad(g) and g.isEnabled ~= false and (g == selGroup or gi == sel.gi) then
        for ci = 1, #items do
          local centre, p0, p1 = host.frameAt(g, items[ci].t or 0.5)
          if centre then
            local isSel = showSelected and sel.kind == kind and gi == sel.gi and ci == sel.ci
            rLines.drawForegroundLine(p0, p1, ghostCol)
            -- Handles at the edges (not the centre) so they clear the centreline node-insert hover.
            if isSel then
              rSpheres.drawSphereHighlightSelectedFixed(p0, handleR)
              rSpheres.drawSphereHighlightSelectedFixed(p1, handleR)
            else
              rSpheres.drawSphereHighlightHoverFixed(p0, handleR * 0.8)
              rSpheres.drawSphereHighlightHoverFixed(p1, handleR * 0.8)
            end
          end
        end
      end
    end
  end
end

-- Hover glow + prompt for the item under the cursor this frame. kind optional -> the hovered / sole kind.
local function drawHover(groups, gi, ci, kind)
  if not gi then return end
  local host = hosts[resolveKind(kind)]
  local hg = host and groups[gi]
  local items = hg and host.itemsOf(hg)
  local item = items and items[ci]
  if not item then return end
  local centre, p0, p1 = host.frameAt(hg, item.t or 0.5)
  if centre then
    rSpheres.drawSphereHighlightHoverFixed(p0, handleR * 1.25)
    rSpheres.drawSphereHighlightHoverFixed(p1, handleR * 1.25)
    rMarkup.markupText(centre, 'drag to move, or CTRL to delete')
  end
end

-- Compact editor for the selected crossing (depth, lateral extent, remove). Only meaningful for a crossing-shaped host
-- (depthM + lateral); roadNetwork uses it. Returns false when the selection is gone (host resets its sel kind).
local function drawEditor()
  local host = sel.kind and hosts[sel.kind]
  local groups = host and host.getGroups()
  local group = groups and sel.gi and groups[sel.gi]
  local items = group and host.itemsOf(group)
  local cr = items and items[sel.ci]
  if not cr then
    sel.kind, sel.gi, sel.ci = nil, nil, nil
    return false
  end
  im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
  im.Text('Pedestrian Crossing')
  im.SameLine()
  if editor.uiIconImageButton(editor.icons.trashBin2, iconsSmall, cols.blueB, nil, nil, 'removeCrossingBtn') then
    local statePre = host.deepCopy(group)
    host.removeItem(group, sel.ci)
    commit(host, 'Remove ' .. host.label, statePre, host.deepCopy(group))
    sel.kind, sel.gi, sel.ci = nil, nil, nil
    im.PopStyleVar()
    return false
  end
  im.tooltip('Remove this crossing.')

  im.PushItemWidth(-1)
  local ptr = im.FloatPtr(cr.depthM or host.defaultDepthM)
  if im.SliderFloat('###crossingDepth', ptr, 1.5, 8.0, 'Depth (m) = %.1f') then
    cr.depthM = ptr[0]
    group.isDirty = true
  end
  im.tooltip('Length of the crossing along the road (zebra band + kerb dip).')
  if im.IsItemActivated() then sliderPreEditState = host.deepCopy(group) end
  if im.IsItemDeactivatedAfterEdit() then
    cr.t = host.clampT(group, cr.t, cr.depthM)
    group.isDirty = true
    commit(host, 'Adjust ' .. host.label .. ' Depth', sliderPreEditState, host.deepCopy(group))
  end
  im.PopItemWidth()

  im.Text('Extent:')
  im.SameLine()
  local wantCarr = cr.lateral ~= 'kerb'
  if im.RadioButton1('Carriageway###crXcarr', wantCarr) and not wantCarr then
    local statePre = host.deepCopy(group)
    cr.lateral = 'carriageway'
    group.isDirty = true
    commit(host, host.label .. ' Extent', statePre, host.deepCopy(group))
  end
  im.SameLine()
  if im.RadioButton1('Kerb to kerb###crXkerb', not wantCarr) and wantCarr then
    local statePre = host.deepCopy(group)
    cr.lateral = 'kerb'
    group.isDirty = true
    commit(host, host.label .. ' Extent', statePre, host.deepCopy(group))
  end
  im.tooltip('Carriageway = kerb line to kerb line. Kerb to kerb also spans the sidewalks.')
  im.PopStyleVar()
  return true
end


-- Public interface.
M.setHost = setHost
M.isPlaceMode = isPlaceMode
M.setPlaceMode = setPlaceMode
M.isDragging = isDragging
M.hasSelection = hasSelection
M.select = select
M.getSelection = getSelection
M.reset = reset
M.underMouse = underMouse
M.clickHandle = clickHandle
M.handlePlacement = handlePlacement
M.handleSelectDrag = handleSelectDrag
M.drawHandles = drawHandles
M.drawHover = drawHover
M.drawEditor = drawEditor

return M