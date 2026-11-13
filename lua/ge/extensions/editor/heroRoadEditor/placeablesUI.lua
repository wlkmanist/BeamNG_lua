-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Features-tab UI for Hero Road placeables (crossings, repair clusters, potholes, widenings, junctions).

local M = {}

-- Module dependencies.
local ffi = require('ffi')
local groupMgr = require('editor/heroRoadEditor/groupMgr')
local barrierMgr = require('editor/heroRoadEditor/barrierMgr')
local session = require('editor/toolUtilities/session')
local roadPlaceables = require('editor/toolUtilities/roadPlaceables')
local panCamera = require('editor/toolUtilities/panCamera')
local util = require('editor/toolUtilities/util')
local style = require('editor/toolUtilities/style')

-- Module constants.
local im = ui_imgui
local cols = style.getImguiCols('crystal')
local iconsSmall, iconsBig = im.ImVec2(24, 24), im.ImVec2(36, 36)

-- Module state.
local crossingEditPre = nil -- pre-edit group snapshot.
local liveDrag = false -- set by a 'live' itemSlider while held; polled + reset each frame by heroRoadEditor (consumeLiveDrag)
                       -- so a widening shaping slider drives the same ribbon-only drag path as dragging a node.

-- Returns whether a live slider was held last frame, and resets the flag (the tool window is drawn after the drag pipeline
-- runs, so heroRoadEditor reads this at the top of the next frame -- same 1-frame pipeline as its own liveSliderDragging).
local function consumeLiveDrag() local v = liveDrag; liveDrag = false; return v end


-- The Features tab's unified placeables list (crossings + repair clusters + potholes + widenings).
local function drawPlaceablesList(selGroup, groupIdx, entries, emptyText)
  local selKind, selGi, selCi = roadPlaceables.getSelection()
  local removeEntry = nil
  im.PushItemWidth(-1)
  if im.BeginListBox('###heroPlaceableList', im.ImVec2(-1, 160)) then
    if #entries == 0 then
      im.TextColored(cols.dullWhite, emptyText)
    else
      im.Columns(3, 'heroPlaceableListCols', true)
      im.SetColumnWidth(0, 30)
      im.SetColumnWidth(1, 170)
      im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(4, 2))
      im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
      local wCtr = 71000
      for e = 1, #entries do
        local en = entries[e]
        local it = en.item
        local isSel = (selKind == en.kind and selGi == groupIdx and selCi == en.idx)
        if im.Selectable1("###" .. tostring(wCtr), isSel, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
          roadPlaceables.select(en.kind, groupIdx, en.idx)
        end
        wCtr = wCtr + 1
        im.SameLine()
        im.NextColumn()

        im.PushItemWidth(170)
        local namePtr = im.ArrayChar(32, it.name or (en.nameFallback .. en.idx))
        if im.InputText("###" .. tostring(wCtr), namePtr, 32) then it.name = ffi.string(namePtr) end
        if im.IsItemActivated() then crossingEditPre = groupMgr.deepCopyGroup(selGroup); roadPlaceables.select(en.kind, groupIdx, en.idx) end
        if im.IsItemDeactivatedAfterEdit() and crossingEditPre then
          editor.history:commitAction(en.renameLabel, { old = crossingEditPre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
          crossingEditPre = nil
        end
        im.tooltip('Edit the name.')
        im.PopItemWidth()
        wCtr = wCtr + 1
        im.SameLine()
        im.NextColumn()

        -- Go-to: fly the camera to this placeable's station (frame the carriageway edges there so a single point is framable).
        if editor.uiIconImageButton(editor.icons.cameraFocusTopDown, iconsSmall, cols.blueB, nil, nil, 'heroPlaceableGoto' .. e) then
          roadPlaceables.select(en.kind, groupIdx, en.idx) -- also select it, so its controls show and it highlights.
          local centre, p0, p1 = groupMgr.crossingFrame(selGroup, it.t or 0.5)
          if centre then
            local pts = { p0, p1, centre }
            if not panCamera.gotoPoints(pts) then util.goToSpline(pts) end
          end
        end
        im.tooltip('Move the camera here.')
        im.SameLine()
        -- Remove is deferred until after the list so we don't mutate mid-iteration.
        if editor.uiIconImageButton(editor.icons.trashBin2, iconsSmall, cols.blueB, nil, nil, 'heroPlaceableRm' .. e) then removeEntry = en end
        im.tooltip('Remove.')
        im.NextColumn()
        im.Separator()
      end
      im.PopStyleVar(2)
    end
    im.EndListBox()
  end
  if removeEntry then
    local statePre = groupMgr.deepCopyGroup(selGroup)
    removeEntry.removeFn(selGroup, removeEntry.idx)
    editor.history:commitAction(removeEntry.removeLabel, { old = statePre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
    roadPlaceables.select(nil, nil, nil)
  end
end

-- itemSlider onChange hook for a crossing's depth: keeps its station clamped inside the road ends for the new depth.
local function reclampCrossingStation(group, cr)
  cr.t = groupMgr.clampCrossingT(group, cr.t, cr.depthM)
end

-- One slider row bound to a placeable ITEM field (not group[key]).
local function itemSlider(selGroup, item, key, default, minV, maxV, fmt, tip, commitLabel, onChange, deferDirty, live, furnitureLive)
  im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
  im.Columns(2, 'ris_c_' .. key, false)
  im.SetColumnWidth(0, 30)
  if item[key] ~= default then
    if editor.uiIconImageButton(editor.icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'ris_reset_' .. key) then
      local pre = groupMgr.deepCopyGroup(selGroup)
      item[key] = default
      if onChange then onChange(selGroup, item) end
      if furnitureLive then
        barrierMgr.updateGroup(selGroup)
        if be and be.reloadCollision then be:reloadCollision() end
        session.markEdited('heroRoadEditor')
      else
        selGroup.isDirty = true
      end
      editor.history:commitAction(commitLabel, { old = pre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
    end
    im.tooltip('Reset to default')
  else
    im.Dummy(iconsSmall)
  end
  im.SameLine()
  im.NextColumn()
  im.PushItemWidth(-1)
  local ptr = im.FloatPtr(item[key] or default)
  local changed = im.SliderFloat('###ris_' .. key, ptr, minV, maxV, fmt)
  if changed then
    item[key] = ptr[0]
    if onChange then onChange(selGroup, item) end
    if furnitureLive then barrierMgr.updateGroup(selGroup) -- re-place the props live along the existing mesh edges (no rebuild).
    elseif not deferDirty then selGroup.isDirty = true end -- deferDirty: hold the rebuild until release (heavy items).
  end
  -- 'live': dirty every frame + flag the drag so the ribbon re-samples each frame while the heavy mesh waits for release.
  if live and im.IsItemActive() then liveDrag = true end
  if tip then im.tooltip(tip) end
  if im.IsItemActivated() then crossingEditPre = groupMgr.deepCopyGroup(selGroup) end
  if im.IsItemDeactivatedAfterEdit() and crossingEditPre then
    if furnitureLive then
      barrierMgr.updateGroup(selGroup) -- final placement + sync the static-prop collision once, and mark the doc edited.
      if be and be.reloadCollision then be:reloadCollision() end
      session.markEdited('heroRoadEditor')
    elseif deferDirty then selGroup.isDirty = true end -- one rebuild on release for a deferred slider.
    editor.history:commitAction(commitLabel, { old = crossingEditPre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
    crossingEditPre = nil
  end
  im.PopItemWidth()
  im.Columns(1)
  im.PopStyleVar()
end

-- Shaping controls for the selected repair cluster: footprint + scatter knobs + a reshuffle seed. Every knob marks the group
-- dirty so repairMgr restamps the decals; the arrangement is fully determined by these + rc.seed.
local function repairClusterControls(selGroup, rc)
  itemSlider(selGroup, rc, 'lengthM', groupMgr.defaultRepairLengthM, 2.0, 40.0, 'Length (m) = %.1f', 'Longitudinal extent of the scatter band along the road.', 'Adjust Repair Length')
  itemSlider(selGroup, rc, 'coverage', 0.6, 0.1, 1.0, 'Coverage = %.2f', 'Lateral spread as a fraction of the carriageway width.', 'Adjust Repair Coverage')
  itemSlider(selGroup, rc, 'offset', 0.0, -1.0, 1.0, 'Offset = %.2f', 'Lateral shift of the band centre (-1 left .. +1 right).', 'Adjust Repair Offset')
  itemSlider(selGroup, rc, 'density', 0.08, 0.02, 0.5, 'Density = %.2f /m2', 'Patches per square metre of the footprint (drives the patch count).', 'Adjust Repair Density')
  itemSlider(selGroup, rc, 'sizeMin', 2.0, 0.5, 6.0, 'Size min (m) = %.2f', 'Smallest patch size.', 'Adjust Repair Size')
  itemSlider(selGroup, rc, 'sizeMax', 4.0, 0.5, 6.0, 'Size max (m) = %.2f', 'Largest patch size.', 'Adjust Repair Size')
  itemSlider(selGroup, rc, 'rotJitter', 0.0, 0.0, 1.0, 'Rotation jitter = %.2f', '0 = patches aligned to the road; 1 = fully random yaw.', 'Adjust Repair Rotation')

  im.Text('Seed: ' .. tostring(rc.seed or 0))
  im.SameLine()
  if editor.uiIconImageButton(editor.icons.casino or editor.icons.refresh, iconsSmall, cols.blueB, nil, nil, 'repairReseedBtn') then
    local pre = groupMgr.deepCopyGroup(selGroup)
    rc.seed = math.random(1, 999)
    selGroup.isDirty = true
    editor.history:commitAction('Reshuffle Repair', { old = pre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
  end
  im.tooltip('Reshuffle the scatter (new random arrangement).')
end

-- Shaping controls for the selected pothole: crater size + depth + shape + a reshuffle seed. Every knob marks the group dirty
-- so the deck mesh (LOD0 + collision) re-carves the crater; the shape is fully determined by these + ph.seed.
local function potholeControls(selGroup, ph)
  -- deferDirty=true on every knob: a pothole re-carves the deck + collision (super-linear createMesh), so rebuild once on
  -- release instead of every drag frame -- otherwise a big radius freezes the whole road mid-drag.
  local defExtM = groupMgr.defaultPotholeRadiusM * 2
  itemSlider(selGroup, ph, 'lengthM', defExtM, 0.5, 12.0, 'Length (m) = %.2f', 'Crater size ALONG the road. Set it longer than the width for a stretched, wheel-rut style pothole.', 'Adjust Pothole Length', nil, true)
  itemSlider(selGroup, ph, 'widthM', defExtM, 0.5, 12.0, 'Width (m) = %.2f', 'Crater size ACROSS the road.', 'Adjust Pothole Width', nil, true)
  itemSlider(selGroup, ph, 'depthM', 0.3, 0.02, 1.0, 'Depth (m) = %.2f', 'Max sink at the crater floor.', 'Adjust Pothole Depth', nil, true)
  itemSlider(selGroup, ph, 'lateralM', 0.0, -8.0, 8.0, 'Lateral (m) = %.2f', 'Lateral offset from the road centreline (+ = right of travel).', 'Adjust Pothole Lateral', nil, true)
  itemSlider(selGroup, ph, 'noise', 0.15, 0.0, 0.25, 'Noise = %.2f', 'Natural variation: 0 = a clean smooth bowl; 0.25 = a ragged, rough rim and floor. Reshuffle the seed for a different look.', 'Adjust Pothole Noise', nil, true)

  -- Cut any painted lines crossing the hole (paint leaves with the pavement) instead of letting the decal drape into it.
  local cutPtr = im.BoolPtr(ph.cutMarkings ~= false)
  if im.Checkbox('Cut road markings', cutPtr) then
    local pre = groupMgr.deepCopyGroup(selGroup)
    ph.cutMarkings = cutPtr[0]
    selGroup.isDirty = true
    editor.history:commitAction('Toggle Pothole Cut Markings', { old = pre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
  end
  im.tooltip('Gap any lane/edge lines that cross this pothole (with a worn, frayed edge) rather than painting down into the hole.')

  im.Text('Seed: ' .. tostring(ph.seed or 0))
  im.SameLine()
  if editor.uiIconImageButton(editor.icons.casino or editor.icons.refresh, iconsSmall, cols.blueB, nil, nil, 'potholeReseedBtn') then
    local pre = groupMgr.deepCopyGroup(selGroup)
    ph.seed = math.random(1, 999)
    selGroup.isDirty = true
    editor.history:commitAction('Reshuffle Pothole', { old = pre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
  end
  im.tooltip('Reshuffle the rim shape (new random arrangement).')
end

-- itemSlider onChange hook for a widening: keeps its station clamped inside the road ends once its length (bay/tapers) changes.
local function reclampWideningStation(group, w)
  w.t = groupMgr.clampCrossingT(group, w.t, groupMgr.wideningExtent(w))
end

-- Undo-batched boolean toggle for a widening's marking flag: flips item[key], marks the group dirty (rebuilds the markings)
-- and commits one undo action.
local function wideningMarkToggle(selGroup, w, key, label, tip, commitLabel)
  local ptr = im.BoolPtr(w[key] == true)
  if im.Checkbox(label, ptr) then
    local pre = groupMgr.deepCopyGroup(selGroup)
    w[key] = ptr[0]
    selGroup.isDirty = true
    editor.history:commitAction(commitLabel, { old = pre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
  end
  im.tooltip(tip)
end

-- Shaping controls for the selected widening: which side it's on, the flat bay's extra width + length + entry/exit tapers,
-- and the two marking options. There is ONE widening type (a flat one-sided bay); a plain layby leaves both marking boxes off
-- (edge line stays straight, bay beyond it), while an overtaking lane ticks both. Every knob marks the group dirty so
-- profile.build reshapes the swept deck (terraform / collision / sidewalks follow) and layerMgr redraws the markings.
local function wideningControls(selGroup, w)
  -- Side radio (which side the bay/lane is added to; the spline stays the carriageway centre).
  im.Text('Side:')
  im.SameLine()
  local onRight = w.side ~= 'left'
  if im.RadioButton1('Left###wsideL', not onRight) and onRight then
    local pre = groupMgr.deepCopyGroup(selGroup)
    w.side = 'left'; selGroup.isDirty = true
    editor.history:commitAction('Widening Side', { old = pre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
  end
  im.SameLine()
  if im.RadioButton1('Right###wsideR', onRight) and not onRight then
    local pre = groupMgr.deepCopyGroup(selGroup)
    w.side = 'right'; selGroup.isDirty = true
    editor.history:commitAction('Widening Side', { old = pre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
  end
  im.tooltip('Which side of the road the bay/lane is added to.')

  -- live=true on every shaping slider: the bay can span hundreds of metres, so a per-frame full mesh rebuild would stutter.
  -- The ribbon (which reflects the widening) re-samples each frame; the heavy mesh settles on release -- exactly like a node drag.
  local p = groupMgr.wideningDefaults()
  itemSlider(selGroup, w, 'widthM', p.widthM, 0.5, 6.0, 'Extra width (m) = %.2f', 'How far the bay/lane extends beyond the normal carriageway edge.', 'Adjust Widening Width', nil, nil, true)
  -- Bay up to 2 km: a realistic overtaking / climbing lane runs ~800-2000 m (a layby is only tens of metres).
  itemSlider(selGroup, w, 'bayLenM', p.bayLenM, 5.0, 2000.0, 'Bay length (m) = %.0f', 'Length of the constant full-width section between the tapers.', 'Adjust Widening Bay Length', reclampWideningStation, nil, true)
  itemSlider(selGroup, w, 'taperInM', p.taperInM, 5.0, 200.0, 'Entry taper (m) = %.0f', 'Diverge taper: how gradually the widening ramps in.', 'Adjust Widening Entry Taper', reclampWideningStation, nil, true)
  itemSlider(selGroup, w, 'taperOutM', p.taperOutM, 5.0, 200.0, 'Exit taper (m) = %.0f', 'Merge taper: how gradually the widening ramps back out.', 'Adjust Widening Exit Taper', reclampWideningStation, nil, true)

  -- Marking options. Off + off = a layby (edge line runs straight, bay is unmarked pavement beyond it). Both on = an
  -- overtaking lane (solid edge follows the widened edge + dashed lane divider along the original edge).
  im.Separator()
  im.Text('Markings:')
  wideningMarkToggle(selGroup, w, 'edgeBulge', 'Bulge edge line around bay',
    'The solid edge line follows the widened outer edge over the bay (off = a layby, edge line stays straight and the bay sits beyond it).',
    'Toggle Widening Edge Bulge')
  wideningMarkToggle(selGroup, w, 'laneDivider', 'Dashed lane divider',
    'Adds a dashed lane line along the original carriageway edge over the bay, turning it into a marked extra lane (e.g. an overtaking lane).',
    'Toggle Widening Lane Divider')
end

-- itemSlider onChange hook for a junction: keeps its station clamped inside the road ends once its length/bevel changes.
local function reclampJunctionStation(group, j)
  j.t = groupMgr.clampCrossingT(group, j.t, groupMgr.junctionExtent(j))
end

-- Shaping controls for the selected junction bell-mouth: which side the side road joins, the flare depth + mouth length +
-- corner bevel, and the markings -- a solid give-way line across the joining half, the joining road's centreline (both radial,
-- toggled separately), plus a break-edge toggle that gaps the trunk edge line across the mouth. Every knob dirties the group so
-- profile.build reshapes the flare (terraform / collision follow) and layerMgr redraws the edge line + junction lines.
local function junctionControls(selGroup, j)
  -- Side radio (which side the flare/apron is on; the spline stays the trunk centre and the centreline is untouched).
  im.Text('Side:')
  im.SameLine()
  local onRight = j.side ~= 'left'
  if im.RadioButton1('Left###jsideL', not onRight) and onRight then
    local pre = groupMgr.deepCopyGroup(selGroup)
    j.side = 'left'; selGroup.isDirty = true
    editor.history:commitAction('Junction Side', { old = pre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
  end
  im.SameLine()
  if im.RadioButton1('Right###jsideR', onRight) and not onRight then
    local pre = groupMgr.deepCopyGroup(selGroup)
    j.side = 'right'; selGroup.isDirty = true
    editor.history:commitAction('Junction Side', { old = pre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
  end
  im.tooltip('Which side of the trunk road the side road joins.')

  -- live=true: the flare spans tens of metres, so ribbon-only per frame + heavy mesh on release (same as a widening / node drag).
  local p = groupMgr.junctionDefaults()
  itemSlider(selGroup, j, 'flareM', p.flareM, 1.0, 12.0, 'Flare width (m) = %.2f', 'How far the bell-mouth apron flares out beyond the normal carriageway edge. On a tight inner curve the flare is squashed to keep the road forward-monotone.', 'Adjust Junction Flare', nil, nil, true)
  itemSlider(selGroup, j, 'lengthM', p.lengthM, 2.0, 60.0, 'Mouth length (m) = %.1f', 'Throat length along the trunk: the width of the opening where the side road meets.', 'Adjust Junction Length', reclampJunctionStation, nil, true)
  itemSlider(selGroup, j, 'bevelM', p.bevelM, 1.0, 30.0, 'Bevel (m) = %.1f', 'Rounded-corner taper each side of the mouth: how gradually the edge line bevels out to the throat and back.', 'Adjust Junction Bevel', reclampJunctionStation, nil, true)

  im.Separator()
  im.Text('Markings:')

  -- Give-way line + joining-road centreline (separate), plus the edge break -- all independent.
  wideningMarkToggle(selGroup, j, 'giveWay', 'Give-way line',
    'A SOLID white line perpendicular to the trunk, from the trunk centreline out to the junction-side edge -- the joining (incoming) half only.',
    'Toggle Junction Give-Way')
  wideningMarkToggle(selGroup, j, 'exitCenterline', 'Joining centreline',
    'The joining road\'s centreline, from the junction-side edge out to the end of the apron. Stops at the give-way line, so it never enters the trunk.',
    'Toggle Junction Centreline')
  wideningMarkToggle(selGroup, j, 'breakEdge', 'Break edge line',
    'Wrap the trunk edge line (and any edge-blend strips) round the bevels and break it across the mouth where the road joins.',
    'Toggle Junction Break Edge')
end

-- itemSlider onChange hook for a barrier: keeps its station clamped inside the road ends once its length changes.
local function reclampBarrierStation(group, b)
  b.t = groupMgr.clampCrossingT(group, b.t, groupMgr.barrierExtent(b))
end

-- Undo-batched barrier type radio (jersey / plastic / guardrail): sets b.type, dirties the group (re-places the rail).
local function barrierTypeRadio(selGroup, b, label, val, tip)
  local cur = (b.type or 'guardrail') == val
  if im.RadioButton1(label, cur) and not cur then
    local pre = groupMgr.deepCopyGroup(selGroup)
    b.type = val; selGroup.isDirty = true
    editor.history:commitAction('Barrier Type', { old = pre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
  end
  im.tooltip(tip)
end

-- Shaping controls for the selected barrier: which side it rides, the run length + lateral offset, and the barrier type.
-- Length/offset defer the rebuild to release (like a pothole) so dragging stays smooth; side/type commit once.
local function barrierControls(selGroup, b)
  -- Side radio (which edge the rail rides).
  im.Text('Side:')
  im.SameLine()
  local onRight = b.side ~= 'left'
  if im.RadioButton1('Left###bsideL', not onRight) and onRight then
    local pre = groupMgr.deepCopyGroup(selGroup)
    b.side = 'left'; selGroup.isDirty = true
    editor.history:commitAction('Barrier Side', { old = pre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
  end
  im.SameLine()
  if im.RadioButton1('Right###bsideR', onRight) and not onRight then
    local pre = groupMgr.deepCopyGroup(selGroup)
    b.side = 'right'; selGroup.isDirty = true
    editor.history:commitAction('Barrier Side', { old = pre, new = groupMgr.deepCopyGroup(selGroup) }, groupMgr.singleGroupEditUndo, groupMgr.singleGroupEditRedo, true)
  end
  im.tooltip('Which edge the rail rides.')

  -- Type radio.
  im.Text('Type:')
  im.SameLine()
  barrierTypeRadio(selGroup, b, 'Guardrail###btypeG', 'guardrail', 'Metal guardrail / crash barrier.')
  im.SameLine()
  barrierTypeRadio(selGroup, b, 'Jersey###btypeJ', 'jersey', 'Concrete Jersey barrier.')
  im.SameLine()
  barrierTypeRadio(selGroup, b, 'Plastic###btypeP', 'plastic', 'Plastic (red/white) barrier.')

  local p = groupMgr.barrierDefaults()
  itemSlider(selGroup, b, 'lengthM', p.lengthM, 4.0, 500.0, 'Length (m) = %.0f', 'Along-road extent of the barrier run.', 'Adjust Barrier Length', reclampBarrierStation, nil, nil, true)
  itemSlider(selGroup, b, 'offsetM', p.offsetM, 0.0, 5.0, 'Lateral offset (m) = %.2f', 'Gap from the mesh outer edge to the rail.', 'Adjust Barrier Offset', nil, nil, nil, true)
  itemSlider(selGroup, b, 'zOffsetM', p.zOffsetM, -2.0, 1.0, 'Z offset (m) = %.2f', 'Extra vertical tweak on top of the standard burial. Raise (+) or sink (-) further; 0 = the standard seat for this type.', 'Adjust Barrier Z Offset', nil, nil, nil, true)
end

-- Draws the whole Features tab for the selected road: the unified placeables list, the Add-button row (crossing / repair /
-- pothole / widening / junction / barrier), then the selected item's controls.
local function draw(selGroup, selectedGroupIdx)
  -- One unified list of every placeable kind, then a button row ("place once"), then the selected item's controls after a
  -- separator -- the standard list -> button row -> selected-controls layout.
  local entries = {}
  if selGroup then
    for i, cr in ipairs(selGroup.crossings or {}) do
      entries[#entries + 1] = { kind = 'crossing', item = cr, idx = i, nameFallback = 'Crossing ',
        renameLabel = 'Rename Crossing', removeLabel = 'Remove Crossing', removeFn = groupMgr.removeCrossing }
    end
    for i, rc in ipairs(selGroup.repairs or {}) do
      entries[#entries + 1] = { kind = 'repair', item = rc, idx = i, nameFallback = 'Repair ',
        renameLabel = 'Rename Repair Cluster', removeLabel = 'Remove Repair Cluster', removeFn = groupMgr.removeRepair }
    end
    for i, ph in ipairs(selGroup.potholes or {}) do
      entries[#entries + 1] = { kind = 'pothole', item = ph, idx = i, nameFallback = 'Pothole ',
        renameLabel = 'Rename Pothole', removeLabel = 'Remove Pothole', removeFn = groupMgr.removePothole }
    end
    for i, wd in ipairs(selGroup.widenings or {}) do
      entries[#entries + 1] = { kind = 'widening', item = wd, idx = i, nameFallback = 'Widening ',
        renameLabel = 'Rename Widening', removeLabel = 'Remove Widening', removeFn = groupMgr.removeWidening }
    end
    for i, jn in ipairs(selGroup.junctions or {}) do
      entries[#entries + 1] = { kind = 'junction', item = jn, idx = i, nameFallback = 'Junction ',
        renameLabel = 'Rename Junction', removeLabel = 'Remove Junction', removeFn = groupMgr.removeJunction }
    end
    for i, bar in ipairs(selGroup.barriers or {}) do
      entries[#entries + 1] = { kind = 'barrier', item = bar, idx = i, nameFallback = 'Barrier ',
        renameLabel = 'Rename Barrier', removeLabel = 'Remove Barrier', removeFn = groupMgr.removeBarrier }
    end
  end
  drawPlaceablesList(selGroup, selectedGroupIdx, entries, 'No features yet.')
  im.Separator()

  im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
  im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
  local placingCr = roadPlaceables.isPlaceMode('crossing')
  if editor.uiIconImageButton(editor.icons.pedestrianCrossing01, iconsBig, cols.blueB, nil, nil, 'addCrossingBtn') then
    roadPlaceables.setPlaceMode(not placingCr, 'crossing')
  end
  im.tooltip(placingCr and 'Click a road to place a crossing (Esc / right-click to cancel).' or 'Place a pedestrian crossing.')
  im.SameLine()
  local placingRp = roadPlaceables.isPlaceMode('repair')
  if editor.uiIconImageButton(editor.icons.build, iconsBig, cols.blueB, nil, nil, 'addRepairBtn') then
    roadPlaceables.setPlaceMode(not placingRp, 'repair')
  end
  im.tooltip(placingRp and 'Click a road to place a repair cluster (Esc / right-click to cancel).' or 'Place a repair-patch cluster.')
  im.SameLine()
  local placingPot = roadPlaceables.isPlaceMode('pothole')
  if editor.uiIconImageButton(editor.icons.terrain_height_lower or editor.icons.lens, iconsBig, cols.blueB, nil, nil, 'addPotholeBtn') then
    roadPlaceables.setPlaceMode(not placingPot, 'pothole')
  end
  im.tooltip(placingPot and 'Click a road to place a pothole (Esc / right-click to cancel).' or 'Place a procedural pothole (carved into the mesh).')
  im.SameLine()
  -- One widening kind (a flat one-sided bay); whether it reads as a layby or an overtaking lane is set per item by its
  -- marking options after placement.
  local placingWd = roadPlaceables.isPlaceMode('widening')
  if editor.uiIconImageButton(editor.icons.roadProfile or editor.icons.roadMarkingOutline or editor.icons.roadStackPlus, iconsBig, cols.blueB, nil, nil, 'addWideningBtn') then
    roadPlaceables.setPlaceMode(not placingWd, 'widening')
  end
  im.tooltip(placingWd and 'Click a road to place a widening (Esc / right-click to cancel).' or 'Place a widening: a flat one-sided bay reshaped into the mesh (layby or overtaking lane, set by its marking options).')
  im.SameLine()
  -- Junction bell-mouth: a one-sided flare on this (trunk) road; a separate road is dragged in to meet the apron.
  local placingJn = roadPlaceables.isPlaceMode('junction')
  if editor.uiIconImageButton(editor.icons.merge_type or editor.icons.call_split or editor.icons.roadStackPlus or editor.icons.build, iconsBig, cols.blueB, nil, nil, 'addJunctionBtn') then
    roadPlaceables.setPlaceMode(not placingJn, 'junction')
  end
  im.tooltip(placingJn and 'Click a road to place a junction (Esc / right-click to cancel).' or 'Place a junction: a one-sided bell-mouth flare on this trunk road for a side road to join (drag a separate road onto the apron).')
  im.SameLine()
  -- Barrier: a guardrail/jersey/plastic run dropped at a spot (e.g. through a corner), on one side over a length. Furniture only.
  local placingBar = roadPlaceables.isPlaceMode('barrier')
  if editor.uiIconImageButton(editor.icons.roadGuideArrowSolid or editor.icons.concreteRoadBlock or editor.icons.build, iconsBig, cols.blueB, nil, nil, 'addBarrierBtn') then
    roadPlaceables.setPlaceMode(not placingBar, 'barrier')
  end
  im.tooltip(placingBar and 'Click a road to place a barrier (Esc / right-click to cancel).' or 'Place a barrier: a guardrail run on one side (set the length, side and type after placing) -- e.g. only through a corner.')
  im.PopStyleVar(2)

  -- Placing any surface feature needs the road's collision mesh to drop / drape onto, so if the artist starts placing while the
  -- procedural preview is pinned off (see the toggle under the road list), switch it back on for this road (rebuilds next pass).
  if selGroup and selGroup.previewMesh == false
     and (roadPlaceables.isPlaceMode('crossing') or roadPlaceables.isPlaceMode('repair')
       or roadPlaceables.isPlaceMode('pothole') or roadPlaceables.isPlaceMode('widening')
       or roadPlaceables.isPlaceMode('junction') or roadPlaceables.isPlaceMode('barrier')) then
    selGroup.previewMesh = true
    selGroup.isDirty = true
  end

  -- Controls for the selected placeable (depth for a crossing; shaping knobs for the others).
  local selKind, selGi, selCi = roadPlaceables.getSelection()
  if selGi == selectedGroupIdx and selGroup then
    if selKind == 'crossing' then
      local cr = selGroup.crossings and selGroup.crossings[selCi]
      if cr then
        im.Separator()
        itemSlider(selGroup, cr, 'depthM', groupMgr.defaultCrossingDepthM, 1.5, 8.0, 'Depth (m) = %.1f',
          'Length of the crossing along the road (zebra band + kerb dip).', 'Adjust Crossing Depth', reclampCrossingStation)
      end
    elseif selKind == 'repair' then
      local rc = selGroup.repairs and selGroup.repairs[selCi]
      if rc then
        im.Separator()
        repairClusterControls(selGroup, rc)
      end
    elseif selKind == 'pothole' then
      local ph = selGroup.potholes and selGroup.potholes[selCi]
      if ph then
        im.Separator()
        potholeControls(selGroup, ph)
      end
    elseif selKind == 'widening' then
      local wd = selGroup.widenings and selGroup.widenings[selCi]
      if wd then
        im.Separator()
        wideningControls(selGroup, wd)
      end
    elseif selKind == 'junction' then
      local jn = selGroup.junctions and selGroup.junctions[selCi]
      if jn then
        im.Separator()
        junctionControls(selGroup, jn)
      end
    elseif selKind == 'barrier' then
      local bar = selGroup.barriers and selGroup.barriers[selCi]
      if bar then
        im.Separator()
        barrierControls(selGroup, bar)
      end
    end
  end
end


-- Public interface.
M.draw = draw
M.consumeLiveDrag = consumeLiveDrag

return M