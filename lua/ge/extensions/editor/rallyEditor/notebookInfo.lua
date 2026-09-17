-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local cc = require('/lua/ge/extensions/gameplay/rally/util/colors')
local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local RallyEnums = require('/lua/ge/extensions/gameplay/rally/enums')

local im  = ui_imgui

local logTag = ''

local calibrationMetadataFields = {
  { key = "cornerIntensity", label = "corner intensity", source = "active style corner intensity IDs" },
  { key = "cornerDescriptor", label = "corner descriptor", source = "active style corner descriptor labels" },
  { key = "direction", label = "direction", source = "active style left/right direction labels" },
  { key = "cornerLength", label = "corner length", source = "active style corner length labels" },
  { key = "shape", label = "shape", source = "active style corner shape labels" },
}

-- notebook form fields
local notebookNameText = im.ArrayChar(1024, "")
local notebookAuthorsText = im.ArrayChar(1024, "")
local notebookDescText = im.ArrayChar(2048, "")

local C = {}
C.windowDescription = 'Notebook'

function C:init(rallyEditor)
  self.rallyEditor = rallyEditor
  self.valid = true
end

function C:clearState()
  self.path = nil
  self.valid = true
  notebookNameText = im.ArrayChar(1024, "")
  notebookAuthorsText = im.ArrayChar(1024, "")
  notebookDescText = im.ArrayChar(2048, "")
end

function C:isValid()
  return self.valid
end

function C:validate()
  self.valid = true

  self.path:validate()
  if not self.path:is_valid() then
    self.valid = false
  end
end

function C:setPath(path)
  self.path = path
end

-- called by RallyEditor when this tab is selected.
function C:selected()
  if not self.path then return end

  notebookNameText = im.ArrayChar(1024, self.path.name)
  notebookAuthorsText = im.ArrayChar(1024, self.path.authors)
  notebookDescText = im.ArrayChar(1024, self.path.description)

  -- force redraw of shortcutLegend window
  extensions.hook("onEditorEditModeChanged", nil, nil)
end

-- called by RallyEditor when this tab is unselected.
function C:unselect()
  if not self.path then return end
  -- force redraw of shortcutLegend window
  extensions.hook("onEditorEditModeChanged", nil, nil)
end

function C:draw(mouseInfo)
  self:drawNotebook()
end

local function setNotebookFieldUndo(data)
  data.self.path[data.field] = data.old
end
local function setNotebookFieldRedo(data)
  data.self.path[data.field] = data.new
end

local function ghostNotebookDisplayName(fname)
  if not fname then return '(none)' end
  local base = tostring(fname):match("([^/\\]+)$") or tostring(fname)
  local display = base:gsub('%.notebook%.json$', '')
  return display
end

function C:drawGhostNotebook()
  im.HeaderText("Ghost Notebook")

  local selectedFname = self.rallyEditor.getGhostNotebookSelectedFname and self.rallyEditor.getGhostNotebookSelectedFname()
  local selectedLabel = self.rallyEditor.getGhostNotebookSelectedLabel and self.rallyEditor.getGhostNotebookSelectedLabel()
    or ghostNotebookDisplayName(selectedFname)
  local choices = self.rallyEditor.listGhostNotebookChoices and self.rallyEditor.listGhostNotebookChoices() or {}

  im.SetNextItemWidth(280)
  if im.BeginCombo("##ghostNotebookPicker", selectedLabel) then
    if im.Selectable1("(none)", selectedFname == nil) then
      if self.rallyEditor.clearGhostNotebook then
        self.rallyEditor.clearGhostNotebook()
      end
    end

    if #choices == 0 then
      im.BeginDisabled()
      im.Selectable1("(no notebooks in this mission)", false)
      im.EndDisabled()
    else
      for _, choice in ipairs(choices) do
        local fname = choice.fname
        local label = choice.label or ghostNotebookDisplayName(fname)
        local isSelected = selectedFname == fname
        if im.Selectable1(label, isSelected) and not isSelected then
          self.rallyEditor.selectGhostNotebook(fname)
        end
      end
    end

    im.EndCombo()
  end
  im.tooltip("Render the selected notebook as a passive grey overlay in the Pacenotes tab.")

  local err = self.rallyEditor.getGhostNotebookError and self.rallyEditor.getGhostNotebookError()
  if err then
    im.TextColored(cc.clr_error, err)
  end
end

local function ensureCalibrationMetadataFields(path)
  path.metadata = path.metadata or {}
  path.metadata.calibrationFields = deepcopy(calibrationMetadataFields)
end

function C:drawCalibrationMetadataFields()
  im.HeaderText("Calibration Metadata Fields")

  local fields = self.path.metadata and self.path.metadata.calibrationFields
  if not fields then
    im.TextWrapped("No notebook-level calibration field definition has been saved yet.")
    if im.Button("Initialize Calibration Fields") then
      ensureCalibrationMetadataFields(self.path)
    end
    im.tooltip("Defines the per-pacenote metadata.calibration fields used by the calibration experiment.")
    return
  end

  for _, field in ipairs(fields) do
    im.Text(string.format("%s (%s)", field.key, field.label or ""))
    if field.source then
      im.SameLine()
      im.TextColored(im.ImVec4(0, 1, 1, 1), "(?)")
      im.tooltip(field.source)
    end
  end
end

function C:drawNotebook()
  if not self.path then return end

  self:validate()

  if self:isValid() then
    im.HeaderText("Notebook Info")
  else
    im.HeaderText("[!] Notebook Info")
    local issues = "Issues (".. (#self.path.validation_issues) .."):\n"
    for _, issue in ipairs(self.path.validation_issues) do
      issues = issues..'- '..issue..'\n'
    end
    im.TextColored(cc.clr_error, issues)
    im.Separator()
  end

  im.Text("Current Notebook: #" .. self.path.id)
  im.Text("File: " .. tostring(self.path.fname))
  im.tooltip(tostring(self.path.fname))

  for _ = 1,5 do im.Spacing() end

  local editEnded = im.BoolPtr(false)
  editor.uiInputText("Name", notebookNameText, nil, nil, nil, nil, editEnded)
  if editEnded[0] then
    editor.history:commitAction("Change Name of Notebook",
      {self = self, old = self.path.name, new = ffi.string(notebookNameText), field = 'name'},
      setNotebookFieldUndo, setNotebookFieldRedo)
  end

  editEnded = im.BoolPtr(false)
  editor.uiInputText("Authors", notebookAuthorsText, nil, nil, nil, nil, editEnded)
  if editEnded[0] then
    editor.history:commitAction("Change Authors of Notebook",
      {self = self, old = self.path.authors, new = ffi.string(notebookAuthorsText), field = 'authors'},
      setNotebookFieldUndo, setNotebookFieldRedo)
  end

  editEnded = im.BoolPtr(false)
  editor.uiInputText("Description", notebookDescText, nil, nil, nil, nil, editEnded)
  if editEnded[0] then
    editor.history:commitAction("Change Description of Notebook",
      {self = self, old = self.path.description, new = ffi.string(notebookDescText), field = 'description'},
      setNotebookFieldUndo, setNotebookFieldRedo)
  end

  im.SetNextItemWidth(150)
  local currentMode = self.path:getAudioMode()
  local notebookAudioModeDisplay = RallyEnums.pacenoteAudioModeDisplayNames[currentMode]
  if im.BeginCombo("Audio Mode##notebookAudioMode", notebookAudioModeDisplay) then
    for _, mode in ipairs(RallyEnums.pacenoteAudioModeNames) do
      if mode ~= "auto" and not RallyEnums.pacenoteAudioModeHidden[mode] then
        local enumVal = RallyEnums.pacenoteAudioMode[mode]
        local displayName = RallyEnums.pacenoteAudioModeDisplayNames[enumVal]
        if im.Selectable1(displayName, enumVal == currentMode) then
          self.path:setAudioMode(enumVal)
        end
      end
    end
    im.EndCombo()
  end

  for _ = 1,3 do im.Spacing() end
  im.Separator()
  self:drawCalibrationMetadataFields()
  im.Separator()
  self:drawGhostNotebook()
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
