-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui

local M = {}

local function playClip(notebook, basename)
  local full = notebook:resolveCustomAudioBasename(basename)
  if full and FS:fileExists(full) then
    Engine.Audio.intercomPlayPacenote({ filename = full })
  end
end

local function drawToolbar(notebook)
  if im.Button("Sync audio files") then
    notebook:syncCustomAudioFromDisk()
  end
  im.tooltip("Refresh the audio folder after a re-export and drop anchors for missing files.")

  im.TextWrapped("All clips in order, grouped by the likely pacenote assignment. Use the crosshair to pick an anchor pacenote in the viewport; the gaps between anchor pacenotes are guessed.")
end

local function clipLabel(transcriptions, basename)
  local entry = transcriptions[basename]
  local desc = entry and entry.description
  return (desc and desc ~= '') and desc or basename
end

local function drawPickHelp(pacenoteToolsWindow, transcriptions)
  if not (pacenoteToolsWindow and pacenoteToolsWindow.getCustomAudioAnchorPickBasename) then return end
  local basename = pacenoteToolsWindow:getCustomAudioAnchorPickBasename()
  if not basename then return end

  im.TextColored(im.ImVec4(0.45, 0.85, 1, 1), "Picking anchor pacenote")
  im.TextWrapped("Click a pacenote sphere in the viewport to anchor \""..clipLabel(transcriptions, basename).."\". Click empty space or press Esc to cancel.")
end

-- Builds the global ordered list of rows. Each pacenote gets a heading row followed
-- by its assigned clip rows.
local function buildRows(notebook)
  local rows = {}
  local groupIndex = 0
  local pacenotes = notebook.pacenotes and notebook.pacenotes.sorted or {}
  if #pacenotes == 0 then
    local basenames = notebook:scanCustomAudioBasenames()
    if #basenames > 0 then
      groupIndex = groupIndex + 1
      table.insert(rows, {
        rowType = 'heading',
        label = "Unassigned audio",
        groupIndex = groupIndex,
        clipCount = #basenames,
      })
      for i, base in ipairs(basenames) do
        table.insert(rows, {
          rowType = 'clip',
          basename = base,
          idxInPacenote = i,
          countInPacenote = #basenames,
          groupIndex = groupIndex,
        })
      end
    end
    return rows
  end

  for _, pn in ipairs(pacenotes) do
    local basenames = notebook:customAudioBasenamesFor(pn)
    groupIndex = groupIndex + 1
    table.insert(rows, {
      rowType = 'heading',
      pacenote = pn,
      groupIndex = groupIndex,
      clipCount = #basenames,
    })
    for i, base in ipairs(basenames) do
      table.insert(rows, {
        rowType = 'clip',
        pacenote = pn,
        basename = base,
        idxInPacenote = i,
        countInPacenote = #basenames,
        groupIndex = groupIndex,
      })
    end
  end
  return rows
end

-- Alternate between two gentle colors so grouping is visible without overwhelming the text.
local function groupColorU32(groupIndex, selected)
  if selected then
    return im.GetColorU322(im.ImVec4(0.45, 1.0, 0.55, 0.34)) -- light green
  end
  local alpha = 0.18
  if groupIndex % 2 == 0 then
    return im.GetColorU322(im.ImVec4(1.0, 0.92, 0.35, alpha)) -- light yellow
  end
  return im.GetColorU322(im.ImVec4(0.72, 0.56, 1.0, alpha)) -- light purple
end

local function drawHeadingRow(selectedPacenote, row)
  local rowH = 22
  local dl = im.GetWindowDrawList()
  local p = im.GetCursorScreenPos()
  local w = im.GetContentRegionAvailWidth()
  local belongsToSelected = selectedPacenote and row.pacenote and (row.pacenote.id == selectedPacenote.id)
  local bg = groupColorU32(row.groupIndex, belongsToSelected)
  im.ImDrawList_AddRectFilled(dl, im.ImVec2(p.x, p.y), im.ImVec2(p.x + w, p.y + rowH), bg, 0)
  im.Dummy(im.ImVec2(4, 0))
  im.SameLine(nil, 2)
  local label = row.label or (row.pacenote and (row.pacenote.name or ('Pacenote '..tostring(row.pacenote.sortOrder)))) or "Audio"
  im.Text(string.format("%s (%d clips)", label, row.clipCount or 0))
end

local function drawRow(notebook, selectedPacenote, pacenoteToolsWindow, transcriptions, anchorInfo, row)
  local rowH = 22
  local dl = im.GetWindowDrawList()
  local p = im.GetCursorScreenPos()
  local w = im.GetContentRegionAvailWidth()

  local belongsToSelected = selectedPacenote and row.pacenote and (row.pacenote.id == selectedPacenote.id)
  local bg = groupColorU32(row.groupIndex, belongsToSelected)
  im.ImDrawList_AddRectFilled(dl, im.ImVec2(p.x, p.y), im.ImVec2(p.x + w, p.y + rowH), bg, 0)

  local full = notebook:resolveCustomAudioBasename(row.basename)
  local exists = full and FS:fileExists(full)
  local playClr = exists and im.ImVec4(1, 1, 1, 1) or im.ImVec4(1, 0.4, 0.4, 1)
  if editor.uiIconImageButton(editor.icons.play_circle_filled, im.ImVec2(16, 16), playClr, nil, nil, '##play_'..row.basename) then
    playClip(notebook, row.basename)
  end
  im.tooltip("Play this audio clip.")

  local anchor = anchorInfo.byBasename[row.basename]

  im.SameLine(nil, 3)
  local pickingThis = pacenoteToolsWindow and pacenoteToolsWindow.isPickingCustomAudioAnchorFor and pacenoteToolsWindow:isPickingCustomAudioAnchorFor(row.basename)
  local hasPacenotes = notebook.pacenotes and notebook.pacenotes.sorted and #notebook.pacenotes.sorted > 0
  local selectDisabled = not hasPacenotes or not (pacenoteToolsWindow and pacenoteToolsWindow.beginCustomAudioAnchorPick)
  if selectDisabled then im.BeginDisabled() end
  local anchorClr = im.ImVec4(0.45, 0.85, 1, 1)
  if pickingThis then
    anchorClr = im.ImVec4(0.45, 1, 0.55, 1)
  elseif selectDisabled then
    anchorClr = im.ImVec4(0.65, 0.65, 0.65, 1)
  end
  if editor.uiIconImageButton(editor.icons.crosshair, im.ImVec2(16, 16), anchorClr, nil, nil, '##anchor_'..row.basename) then
    pacenoteToolsWindow:beginCustomAudioAnchorPick(row.basename)
  end
  if selectDisabled then im.EndDisabled() end
  if pickingThis then
    im.tooltip("Picking anchor pacenote in the viewport.")
  else
    im.tooltip((not hasPacenotes) and "Create a pacenote before assigning anchors." or (selectDisabled and "Anchor picker unavailable." or "Pick anchor pacenote in viewport."))
  end

  im.SameLine(nil, 3)
  local clearDisabled = not anchor
  if clearDisabled then im.BeginDisabled() end
  local clearIcon = editor.icons.abandon or editor.icons.close
  local clearClr = anchor and im.ImVec4(1, 0.6, 0.45, 1) or im.ImVec4(0.65, 0.65, 0.65, 1)
  if editor.uiIconImageButton(clearIcon, im.ImVec2(16, 16), clearClr, nil, nil, '##clear_'..row.basename) then
    notebook:clearCustomAudioAnchor(row.basename)
  end
  if clearDisabled then im.EndDisabled() end
  im.tooltip(anchor and "Clear anchor" or "No anchor to clear")

  im.SameLine(nil, 3)
  -- prefer the mission voicepack's transcription text; fall back to the raw basename.
  local clipText = clipLabel(transcriptions, row.basename)
  im.Text(clipText)
  local tooltip = row.basename
  if anchor then
    tooltip = tooltip.."\nanchored to "..(anchor.pacenote.name or ('Pacenote '..tostring(anchor.noteIndex)))
    if anchor.invalid then
      tooltip = tooltip.."\nWARNING: anchor conflicts with another anchor's order."
    end
  end
  im.tooltip(tooltip)
end

function M.draw(notebook, selectedPacenote, pacenoteToolsWindow)
  if not notebook or not notebook.customAudioBasenamesFor then
    im.Text("Custom audio unavailable (no notebook).")
    return
  end

  drawToolbar(notebook)

  local rows = buildRows(notebook)
  if #rows == 0 then
    im.TextColored(im.ImVec4(1, 0.5, 0.5, 1), "(no audio files found - check the voicepack's audio/ folder, then Sync)")
    return
  end

  local transcriptions = notebook:loadCustomPacenoteTranscriptions() or {}
  local anchorInfo = notebook:getCustomAudioAnchorInfo()
  drawPickHelp(pacenoteToolsWindow, transcriptions)

  im.BeginChild1("customAudioList", im.ImVec2(0, 0), im.WindowFlags_ChildWindow)
  for _, row in ipairs(rows) do
    if row.rowType == 'heading' then
      drawHeadingRow(selectedPacenote, row)
    else
      drawRow(notebook, selectedPacenote, pacenoteToolsWindow, transcriptions, anchorInfo, row)
    end
  end
  im.EndChild()
end

return M
