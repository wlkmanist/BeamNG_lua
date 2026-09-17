-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui

local cc = require('/lua/ge/extensions/gameplay/rally/util/colors')
local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local RallyEnums = require('/lua/ge/extensions/gameplay/rally/enums')
local Structured = require('/lua/ge/extensions/gameplay/rally/notebook/structured')
local StructuredForm = require('/lua/ge/extensions/editor/rallyEditor/pacenotes/structuredForm')
local CustomForm = require('/lua/ge/extensions/editor/rallyEditor/pacenotes/customForm')
local MeasurementsForm = require('/lua/ge/extensions/editor/rallyEditor/pacenotes/measurementsForm')
local CalibrationMetadataForm = require('/lua/ge/extensions/editor/rallyEditor/pacenotes/calibrationMetadataForm')
local C = {}

local pacenoteUnderEdit = nil
local editingNote = false
local showDeleteConfirmDialog = false

local playbackRulesHelpText = [[Playback Rules

Available variables:
- currLap (the current lap)
- maxLap  (the maximum lap)

Any lua code is allowed, so be careful. Examples:
- '' (empty string, the default) -> audio will play
- 'true' -> audio will play
- 'false' -> audio will not play
- 'currLap > 1' -> audio will play except for on the first lap
- 'currLap == 3' -> audio will play only on the 3rd lap
- 'currLap ~= 3' -> audio will play except on the 3rd lap
- 'currLap < maxLap' -> audio will play except for on the last lap
]]

function C:init(pacenoteToolsWindow)
  self.pacenoteToolsWindow = pacenoteToolsWindow
  self.pacenoteToolsState = pacenoteToolsWindow.pacenoteToolsState
  self:setPacenote(nil)
end

function C:setPacenote(pacenote)
  self.pacenote = pacenote
  StructuredForm.clear()
  CustomForm.clear()
  MeasurementsForm.clear()
end

function C:clearState()
  pacenoteUnderEdit = nil
  editingNote = false
  showDeleteConfirmDialog = false
  self:setPacenote(nil)
end

local function dumpPacenote(pacenote)
  local dumpData = {
    structured = {
      items = Structured.slotItems(pacenote.structured),
    },
    fnames = {
      freeform = pacenote:audioFnameFreeform(),
      structuredOnline = pacenote:audioFnamesStructuredOnline(),
      structuredOffline = pacenote:audioFnamesStructuredOffline(),
    },
  }
  -- dump(dumpData)
end

local function structuredAudioFolder(pacenote)
  local fnames = nil
  if pacenote:getAudioMode() == RallyEnums.pacenoteAudioMode.structuredOnline then
    fnames = pacenote:audioFnamesStructuredOnline()
  elseif pacenote:getAudioMode() == RallyEnums.pacenoteAudioMode.structuredOffline then
    fnames = pacenote:audioFnamesStructuredOffline()
  end

  if fnames and fnames[1] then
    return path.dirname(fnames[1])
  end
  return nil
end

local function drawStructuredAudioFolderButtons(pacenote)
  local folder = structuredAudioFolder(pacenote)
  if not folder then return end

  im.SameLine()
  if editor.uiIconImageButton(editor.icons.folder_open, im.ImVec2(20, 20), im.ImVec4(1, 1, 1, 1)) then
    Engine.Platform.exploreFolder(folder)
  end
  im.tooltip("Open audio files folder in explorer.")

  im.SameLine()
  if editor.uiIconImageButton(editor.icons.content_copy, im.ImVec2(20, 20), im.ImVec4(1, 1, 1, 1)) then
    im.SetClipboardText(folder)
  end
  im.tooltip("Copy audio files folder path to clipboard.")
end

local function freeformForm(pacenote, pacenoteToolsState, pacenoteToolsWindow)
  local codriver = pacenote:selectedCodriver()

  im.PushFont3("cairo_semibold_large")
  im.Text(pacenote:noteOutputFreeform())
  im.PopFont()

  local file_exists = false
  local voicePlayClr = nil
  local tooltipStr = nil
  local fname = nil

  fname = pacenote:audioFnameFreeform()
  if FS:fileExists(fname) then
    file_exists = true
    tooltipStr = "Co-driver: "..codriver.name.."\nPlay pacenote audio file:\n"..fname
    tooltipStr = tooltipStr.."\n\nClick to copy path to clipboard."
  else
    voicePlayClr = im.ImVec4(0.5, 0.5, 0.5, 1.0)
    tooltipStr = "Co-driver: "..codriver.name.."\nPacenote audio file not found:\n"..fname
    tooltipStr = tooltipStr.."\n\nClick to copy path to clipboard."
  end

  if editor.uiIconImageButton(editor.icons.play_circle_filled, im.ImVec2(20, 20), voicePlayClr) then
    im.SetClipboardText(fname)
    if file_exists then
      Engine.Audio.intercomPlayPacenote({ filename=fname })
    end
  end
  im.tooltip(tooltipStr)

  -- local codriverHelpTxt = "codriver source=mission name="..codriver.name.." language="..codriver.language.." voice="..codriver.voice
  -- im.Text(codriverHelpTxt)
  -- im.tooltip(codriverHelpTxt)

  im.Separator()

  im.HeaderText("Edit - Freeform")

  local editEnded = im.BoolPtr(false)
  -- local freeformBefore = im.ArrayChar(1024, pacenote:getNoteFieldBefore())
  local freeformNote   = im.ArrayChar(1024, pacenote:getNoteFieldFreeform())
  -- local freeformAfter  = im.ArrayChar(1024, pacenote:getNoteFieldAfter())

  -- editor.uiInputText('##distBefore', freeformBefore, nil, nil, nil, nil, editEnded)
  -- if editEnded[0] then
  --   pacenote:clearTodo()
  --   local newVal = ffi.string(freeformBefore)
  --   pacenote:setNoteFieldBefore(newVal)
  --   pacenote:refreshFreeform()
  -- end
  -- im.PushFont3("cairo_regular_medium")
  local distBefore = pacenote:getNoteFieldBefore()
  if distBefore ~= "" then
    im.Text('"'..distBefore..'" ')
  else
    im.Text('<none> ')
  end
  -- im.PopFont()
  im.SameLine()
  im.Text('(distance before, var='..rallyUtil.var_db..')')

  if pacenoteToolsState.insertMode then
    im.SetKeyboardFocusHere()
    pacenoteToolsState.insertMode = false
  end

  im.PushFont3("cairo_regular_medium")
  editingNote = editor.uiInputText('##note', freeformNote, nil, nil, nil, nil, editEnded)
  if editEnded[0] then
    if pacenoteUnderEdit and pacenote.id == pacenoteUnderEdit.id then
      pacenote:clearTodo()
      local newVal = ffi.string(freeformNote)
      pacenote:setNoteFieldFreeform(newVal)
      pacenote:refreshFreeform()
      pacenoteToolsWindow:markValidationDirty()
    end
  end
  im.SameLine()
  im.Text('Pacenote text')
  im.PopFont()

  if editingNote and not pacenoteUnderEdit then
    pacenoteUnderEdit = pacenote
  elseif not editingNote then
    pacenoteUnderEdit = nil
  end

  local distAfter = pacenote:getNoteFieldAfter()
  if distAfter ~= "" then
    im.Text('"'..distAfter..'" ')
  else
    im.Text('<none> ')
  end
  im.SameLine()
  im.Text('(distance after, var='..rallyUtil.var_da..')')

  im.Spacing()
  im.Spacing()
  im.Text("Variables may be used in Pacenote text for custom distance call placement.")
  im.Spacing()

  if im.Button("Generate from Structured") then
    pacenote:generateFreeformFromStructured()
    pacenoteToolsWindow:markValidationDirty()
  end
  im.tooltip(dumps(pacenote:getNoteFieldStructured()))
end

local function dropdownTriggerTypes()
  local keys = {}
  for k,v in pairs(RallyEnums.triggerTypeName) do
    table.insert(keys, k)
  end

  table.sort(keys)

  local types = {}
  for _,k in ipairs(keys) do
    table.insert(types, { k, RallyEnums.triggerTypeName[k] })
  end

  return types
end

local function drawPacenoteActions(pacenote, pacenoteToolsState, pacenoteToolsWindow)
  -- im.Text("Current Pacenote: #" .. self.pacenote_tools_state.selected_pn_id)

  -- if im.Button("Focus Camera") then
  --   self:setCameraToPacenote()
  -- end
  -- im.SameLine()
  if im.Button("Place Vehicle") then
    pacenoteToolsWindow:placeVehicleAtPacenote()
  end
  im.SameLine()

  -- if pacenoteToolsState.snaproad and pacenoteToolsState.snaproad:isRouteSourced() then
  --   im.BeginDisabled()
  -- end
  -- local paused = simTimeAuthority.getPause()
  -- if paused then
  --   im.Text('Unpause game to play Camera Path')
  -- else
  --   local camTxt = 'Play Camera Path'
  --   if pacenoteToolsWindow:cameraPathIsPlaying() then
  --     camTxt = 'Stop Camera Path'
  --   end

  --   if im.Button(camTxt) then
  --     pacenoteToolsWindow:cameraPathPlay()
  --   end
  -- end
  -- im.SameLine()

  -- local corner_call_txt = 'Show Corner Calls'
  -- if pacenoteToolsState.snaproad and pacenoteToolsState.snaproad.show_corner_calls then
  --   corner_call_txt = 'Hide Corner Calls'
  -- end
  -- if im.Button(corner_call_txt) then
  --   pacenoteToolsWindow:toggleCornerCalls()
  -- end
  -- if pacenoteToolsState.snaproad and pacenoteToolsState.snaproad:isRouteSourced() then
  --   im.EndDisabled()
  -- end

  if im.Button("TODO") then
    -- local pn = pacenoteToolsWindow:selectedPacenote()
    -- if pn then
    --   pn:markTodo()
    -- end
    pacenote:markTodo()
    pacenoteToolsWindow:markValidationDirty()
  end
  im.SameLine()
  if im.Button("Done") then
    -- local pn = pacenoteToolsWindow:selectedPacenote()
    -- if pn then
    --   pn:clearTodo()
    -- end
    pacenote:clearTodo()
    pacenoteToolsWindow:markValidationDirty()
  end
  im.SameLine()

  if im.Button("Delete...") then
    showDeleteConfirmDialog = true
  end
  drawStructuredAudioFolderButtons(pacenote)

  -- if im.Button("Dump") then
  --   dumpPacenote(pacenote)
  -- end

  if not pacenote:useStructured() then
    im.SameLine()
    if im.Button("Merge with Prev") then
      pacenoteToolsWindow:mergeSelectedWithPrevPacenote()
    end
    im.SameLine()
    if im.Button("Merge with Next") then
      pacenoteToolsWindow:mergeSelectedWithNextPacenote()
    end
  end
end

local function drawPacenoteStatus(pacenote)
  local todoTextColor = im.ImVec4(1.0, 0.45, 0.05, 1.0)
  local hasIssues = not pacenote:is_valid()

  im.SameLine()
  if hasIssues then
    im.TextColored(cc.clr_error, "Issues: ".. (#pacenote.validation_issues) .. " (hover)")
    local issues = ""
    for _, issue in ipairs(pacenote.validation_issues) do
      issues = issues..'- '..issue..'\n'
    end
    im.PushStyleColor2(im.Col_Text, cc.clr_error)
    im.tooltip(issues)
    im.PopStyleColor()
    if pacenote.todo then
      im.SameLine()
      im.TextColored(todoTextColor, "Marked TODO")
    end
  else
    im.TextColored(cc.clr_no_error, "No issues")
    if pacenote.todo then
      im.SameLine()
      im.TextColored(todoTextColor, "Marked TODO")
    end
  end
end

local function drawPacenoteForm(pacenote, pacenoteToolsState, pacenoteToolsWindow)
  if pacenote.missing then return end

  im.HeaderText(pacenote.name or "Pacenote")
  drawPacenoteStatus(pacenote)
  drawPacenoteActions(pacenote, pacenoteToolsState, pacenoteToolsWindow)

  -- local editEnded = im.BoolPtr(false)
  -- language_form_fields[language] = language_form_fields[language] or {}
  -- local fields = language_form_fields[language]

  -- fields.before = im.ArrayChar(256, pacenote:getNoteFieldBefore())
  -- fields.note   = im.ArrayChar(1024, pacenote:getNoteFieldFreeform())
  -- fields.after  = im.ArrayChar(256, pacenote:getNoteFieldAfter())

  if pacenote:isAudioModeStructuredOnline() or pacenote:isAudioModeStructuredOffline() then
    StructuredForm.draw(pacenote, pacenoteToolsWindow)
  elseif pacenote:isAudioModeFreeform() then
    freeformForm(pacenote, pacenoteToolsState, pacenoteToolsWindow)
  elseif pacenote:isAudioModeCustom() then
    CustomForm.draw(pacenote)
  end

  CalibrationMetadataForm.draw(pacenote, pacenoteToolsWindow)

  im.Separator()
  MeasurementsForm.draw(pacenote, pacenoteToolsState, pacenoteToolsWindow)

  im.Separator()
  im.HeaderText("Options")

  local pacenoteAudioModeEnum = pacenote:getAudioModeSetting()
  local pacenoteAudioModeDisplay = RallyEnums.pacenoteAudioModeDisplayNames[pacenoteAudioModeEnum]
  -- local notebookAudioModeDisplay = RallyEnums.pacenoteAudioModeDisplayNames[pacenote.notebook:getAudioMode()]
  -- im.Text("audioMode notebook="..notebookAudioModeDisplay.." pacenote="..pacenoteAudioModeDisplay)

  im.SetNextItemWidth(150)
  if im.BeginCombo("Audio Mode Override##pacenoteAudioMode", pacenoteAudioModeDisplay) then
    for _, mode in ipairs(RallyEnums.pacenoteAudioModeNames) do
      if not RallyEnums.pacenoteAudioModeHidden[mode] then
        local enumVal = RallyEnums.pacenoteAudioMode[mode]
        local displayName = RallyEnums.pacenoteAudioModeDisplayNames[enumVal]
        if im.Selectable1(displayName, enumVal == pacenoteAudioModeEnum) then
          pacenote:setAudioMode(enumVal)
          pacenoteToolsWindow:markValidationDirty()
        end
      end
    end
    im.EndCombo()
  end
  im.tooltip("Override the audio mode just for this pacenote.\nIn a custom-mode notebook, set a pacenote to structured to use the fallback global voicepack for that note.")

  -- Trigger types are managed automatically during pacenote refresh, so this is
  -- shown read-only to explain the current value without inviting manual edits.
  local currTriggerType = pacenote:getTriggerType()
  local currVal = RallyEnums.triggerTypeName[currTriggerType]
  im.BeginDisabled()
  im.SetNextItemWidth(150)
  if im.BeginCombo('Trigger Type##triggerType', currVal) then
    for _,triggerType in ipairs(dropdownTriggerTypes()) do
      local k = triggerType[1]
      local v = triggerType[2]
      im.Selectable1(v, k == currTriggerType)
    end
    im.EndCombo()
  end
  im.EndDisabled()
  im.SameLine()
  im.TextColored(im.ImVec4(0, 1, 1, 1), "(?)")
  im.tooltip("Read-only: trigger type is managed automatically during pacenote refresh.")

  -- local editEnded = im.BoolPtr(false)
  -- local playbackRulesText = im.ArrayChar(1024, pacenote.playback_rules or "")
  -- im.SetNextItemWidth(150)
  -- editor.uiInputText("Playback Rules", playbackRulesText, nil, nil, nil, nil, editEnded)
  -- if editEnded[0] then
  --   pacenote.playback_rules = ffi.string(playbackRulesText)
  -- end
  -- im.tooltip(playbackRulesHelpText)

  -- Delete confirmation dialog
  if showDeleteConfirmDialog then
    im.OpenPopup("Delete Pacenote?")
    showDeleteConfirmDialog = false
  end

  if im.BeginPopupModal("Delete Pacenote?", nil, im.WindowFlags_AlwaysAutoResize) then
    im.Text("Are you sure you want to delete this pacenote?")
    im.Spacing()
    im.Separator()
    im.Spacing()

    if im.Button("OK", im.ImVec2(120, 0)) then
      pacenoteToolsWindow:deleteSelectedPacenote()
      im.CloseCurrentPopup()
    end
    im.SameLine()
    if im.Button("Cancel", im.ImVec2(120, 0)) then
      im.CloseCurrentPopup()
    end

    im.EndPopup()
  end
end

function C:draw()
  im.BeginChild1("##pacenoteFormChildWindow", nil, im.WindowFlags_ChildWindow)
  if self.pacenote then
    drawPacenoteForm(self.pacenote, self.pacenoteToolsState, self.pacenoteToolsWindow)
  else
    im.Text("No pacenote selected")
  end
  im.EndChild()
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
