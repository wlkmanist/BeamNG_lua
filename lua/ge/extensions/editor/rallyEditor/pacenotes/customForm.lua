-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local RallyEnums = require('/lua/ge/extensions/gameplay/rally/enums')

local im  = ui_imgui
local logTag = ''

local FIELD_WIDTH = 250

local M = {}

local function markValidationDirty()
  if editor_rallyEditor and editor_rallyEditor.getPacenotesWindow then
    local w = editor_rallyEditor.getPacenotesWindow()
    if w and w.markValidationDirty then w:markValidationDirty() end
  end
end

-- Slow corner + release type. These are the same underlying pacenote fields the
-- structured form edits, surfaced here for custom-mode pacenotes too.
local function drawSlowCornerFields(pacenote)
  if im.Checkbox("Slow Corner", im.BoolPtr(pacenote.slowCorner)) then
    pacenote:toggleSlowCorner()
    markValidationDirty()
  end
  im.tooltip("This corner is taken slowly; the next pacenote's call is delayed until the release point.")

  local currReleaseType = pacenote:getSlowCornerReleaseType()
  local currVal = RallyEnums.slowCornerReleaseTypeName[currReleaseType]
  im.SetNextItemWidth(FIELD_WIDTH)
  if im.BeginCombo('Slow Corner Release Type##slowCornerReleaseType', currVal) then
    local keys = {}
    for k, _ in pairs(RallyEnums.slowCornerReleaseTypeName) do table.insert(keys, k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
      if im.Selectable1(RallyEnums.slowCornerReleaseTypeName[k], k == currReleaseType) then
        pacenote:setSlowCornerReleaseType(k)
        markValidationDirty()
      end
    end
    im.EndCombo()
  end
  im.SameLine()
  im.TextColored(im.ImVec4(0, 1, 1, 1), "(?)")
  im.tooltip("The point along this corner at which the slow corner is considered done.\nUntil that point is reached, the next pacenote's call is delayed.")
end

local function baseOf(full)
  return string.match(full, "([^/\\]+)$") or full
end

local function playFile(fname)
  if fname and fname ~= '' and FS:fileExists(fname) then
    Engine.Audio.intercomPlayPacenote({ filename = fname })
  end
end

local function drawAssignedClips(pacenote)
  local fnames = pacenote:getCustomAudioFiles()
  if #fnames == 0 then
    im.TextColored(im.ImVec4(1, 0.5, 0.5, 1), "(no audio files assigned to this pacenote)")
    return
  end

  im.HeaderText("Assigned audio")
  local transcriptions = pacenote.notebook:loadCustomPacenoteTranscriptions() or {}
  for _, fname in ipairs(fnames) do
    local base = baseOf(fname)
    local entry = transcriptions[base]
    local desc = entry and entry.description
    local label = (desc and desc ~= '') and desc or base
    local exists = FS:fileExists(fname)
    local playClr = exists and im.ImVec4(1, 1, 1, 1) or im.ImVec4(1, 0.4, 0.4, 1)
    if editor.uiIconImageButton(editor.icons.play_circle_filled, im.ImVec2(18, 18), playClr, nil, nil, '##customFormPlay_'..base) then
      playFile(fname)
    end
    im.SameLine()
    im.TextWrapped(label)
    im.tooltip(base)
  end
end

M.draw = function(pacenote)
  drawSlowCornerFields(pacenote)
  im.Separator()

  local customPreview = pacenote:noteOutputCustom()
  if customPreview then
    im.PushFont3("cairo_semibold_large")
    im.TextWrapped(customPreview)
    im.PopFont()
  end

  local dir = pacenote:customAudioFileDir()
  if editor.uiIconImageButton(editor.icons.folder_open, im.ImVec2(20, 20), im.ImVec4(1, 1, 1, 1)) then
    if dir and not FS:directoryExists(dir) then
      FS:directoryCreate(dir)
    end
    Engine.Platform.exploreFolder(dir)
  end
  im.tooltip("Open audio files folder in explorer.")

  im.SameLine()
  if editor.uiIconImageButton(editor.icons.content_copy, im.ImVec2(20, 20), im.ImVec4(1, 1, 1, 1)) then
    im.SetClipboardText(dir or '')
  end
  im.tooltip("Copy audio files folder path to clipboard.")

  im.Separator()
  drawAssignedClips(pacenote)
end

M.clear = function()
end

return M
