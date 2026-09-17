-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local compositorUtil = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/compositorUtil')
local Structured = require('/lua/ge/extensions/gameplay/rally/notebook/structured')

local logTag = ''

local C = {}
local metadataGhostFname = '<metadata>'

local modifierLabels = {
  bump = 'bump',
  bumpy = 'bumpy',
  crest = 'crest',
  dontCut = "don't cut",
  finish = 'finish',
  jump = 'jump',
  narrows = 'narrows',
  start = 'start',
  stopControl = 'stop control',
  water = 'water',
}

local directionLabels = {
  [-1] = 'left',
  [0] = 'straight',
  [1] = 'right',
}

local function basenameNoNotebookExt(fname)
  local base = fname and (tostring(fname):match("([^/\\]+)$") or tostring(fname)) or nil
  if not base then return nil end
  local withoutNotebookJson = base:gsub('%.notebook%.json$', '')
  return withoutNotebookJson
end

local function basename(fname)
  if not fname then return '(none)' end
  return (tostring(fname):match("([^/\\]+)$") or tostring(fname))
end

local function displayNameForFname(fname)
  if fname == metadataGhostFname then return metadataGhostFname end
  return basenameNoNotebookExt(fname) or basename(fname)
end

local function isMetadataGhost(fname)
  return fname == metadataGhostFname
end

local function joinLines(lines)
  if type(lines) ~= 'table' then return nil end

  local out = {}
  for _, line in ipairs(lines) do
    if type(line) == 'string' and line ~= '' then
      table.insert(out, line)
    end
  end

  if #out == 0 then return nil end
  return table.concat(out, ' ')
end

local function legacyEnglishLabel(pacenote)
  local english = pacenote.notes and pacenote.notes.english
  if not english then return nil end

  local outLabel = english._out and joinLines(english._out.structured)
  if outLabel then return outLabel end

  if english.note then
    return joinLines(english.note.structured)
  end
  return nil
end

local function formatNumber(value)
  local n = tonumber(value)
  if not n then return nil end
  if math.floor(n) == n then
    return tostring(n)
  end
  return string.format('%.1f', n)
end

local function cautionLabel(item)
  local level = tonumber(item.level) or 1
  if level >= 3 then return 'triple caution' end
  if level >= 2 then return 'double caution' end
  return 'caution'
end

local function cornerLabel(item)
  local parts = {}

  if item.descriptor then
    table.insert(parts, item.descriptor)
  else
    local intensity = formatNumber(item.intensity)
    if intensity then table.insert(parts, intensity) end
  end

  local direction = directionLabels[tonumber(item.direction) or 0]
  if direction and direction ~= 'straight' then
    table.insert(parts, direction)
  elseif #parts == 0 then
    table.insert(parts, direction or 'corner')
  end

  local arcDegrees = formatNumber(item.arcDegrees)
  if arcDegrees then
    table.insert(parts, arcDegrees .. 'deg')
  end

  if item.shape then
    table.insert(parts, item.shape)
  end

  if #parts == 0 then return nil end
  return table.concat(parts, ' ')
end

local function labelFromStructuredItems(pacenote)
  local items = Structured.orderedItems(pacenote.structured)
  if #items == 0 then return nil end

  local out = {}
  for _, item in ipairs(items) do
    if type(item) == 'table' then
      local label = nil
      if item.type == 'caution' then
        label = cautionLabel(item)
      elseif item.type == 'corner' then
        label = cornerLabel(item)
      else
        label = modifierLabels[item.type] or item.type
      end

      if label and label ~= '' then
        table.insert(out, label)
      end
    end
  end

  if #out == 0 then return nil end
  return table.concat(out, ' ')
end

local function composedStructuredLabel(pacenote)
  if not (pacenote.notebook and pacenote.notebook.getActiveCompositorName and pacenote.notebook:getActiveCompositorName()) then
    return nil
  end

  if pacenote.noteOutputStructuredOffline then
    local ok, lines = pcall(function() return pacenote:noteOutputStructuredOffline() end)
    if ok then
      local label = joinLines(lines)
      if label then return label end
    end
  end

  if pacenote.noteOutputStructuredOnline then
    local ok, lines = pcall(function() return pacenote:noteOutputStructuredOnline('english') end)
    if ok then
      return joinLines(lines)
    end
  end
  return nil
end

local function isCustomAudioPacenote(pacenote)
  return pacenote and pacenote.isAudioModeCustom and pacenote:isAudioModeCustom()
end

local function customAudioLabel(pacenote)
  if not isCustomAudioPacenote(pacenote) then return nil end
  if pacenote.noteOutputCustom then
    local ok, label = pcall(function() return pacenote:noteOutputCustom() end)
    if ok and type(label) == 'string' and label ~= '' then return label end
  end

  if not pacenote.getCustomDescription then return '' end

  local ok, label = pcall(function() return pacenote:getCustomDescription() end)
  if not ok or type(label) ~= 'string' then return '' end
  return label
end

local function labelForPacenote(pacenote)
  if not pacenote then return nil end

  if isCustomAudioPacenote(pacenote) then
    return customAudioLabel(pacenote)
  end

  return legacyEnglishLabel(pacenote)
    or composedStructuredLabel(pacenote)
    or labelFromStructuredItems(pacenote)
    or pacenote.name
end

local function cornerIntensityLabel(pacenote, intensityId)
  if not intensityId or intensityId == "" then return nil end

  local compositor = pacenote.notebook and pacenote.notebook:getTextCompositor()
  local config = compositor and compositor:getConfig()
  local cornerCfg = config and config.componentTypes and config.componentTypes.corner
  for _, entry in ipairs(compositorUtil.cornerIntensityList(cornerCfg) or {}) do
    if compositorUtil.intensityEntryId(entry) == intensityId then
      return compositorUtil.intensityEntryLabel(entry)
    end
  end
  return intensityId
end

local function calibrationMetadataLabel(pacenote)
  local calibration = pacenote and pacenote.metadata and pacenote.metadata.calibration
  if not calibration then return nil end

  local parts = {}
  if calibration.cornerDescriptor and calibration.cornerDescriptor ~= "" then
    table.insert(parts, calibration.cornerDescriptor)
  elseif calibration.cornerIntensity and calibration.cornerIntensity ~= "" then
    table.insert(parts, cornerIntensityLabel(pacenote, calibration.cornerIntensity))
  end
  if calibration.direction and calibration.direction ~= "" then
    table.insert(parts, calibration.direction)
  end
  if calibration.cornerLength and calibration.cornerLength ~= "" then
    table.insert(parts, calibration.cornerLength)
  end
  if calibration.shape and calibration.shape ~= "" then
    table.insert(parts, calibration.shape)
  end

  if #parts == 0 then return nil end
  return table.concat(parts, ' ')
end

function C:init(rallyEditor)
  self.rallyEditor = rallyEditor
  self:clear()
end

function C:clear()
  self.selectedFname = nil
  self.path = nil
  self.labels = {}
  self.error = nil
end

function C:clearState()
  self:clear()
end

function C:listChoices()
  local missionDir = self.rallyEditor.getCurrentMissionDir and self.rallyEditor.getCurrentMissionDir()
  if not missionDir then return {} end

  local choices = {}
  table.insert(choices, {
    fname = metadataGhostFname,
    basename = metadataGhostFname,
    label = metadataGhostFname,
  })

  for _, notebookBasename in ipairs(rallyUtil.listNotebooks(missionDir) or {}) do
    local fname = rallyUtil.getNotebookFullPath(missionDir, notebookBasename)
    table.insert(choices, {
      fname = fname,
      basename = notebookBasename,
      label = displayNameForFname(fname),
    })
  end
  return choices
end

function C:activeNotebook()
  local pacenotesWindow = self.rallyEditor.getPacenotesWindow and self.rallyEditor.getPacenotesWindow()
  return pacenotesWindow and pacenotesWindow.path or nil
end

function C:select(fname)
  if not fname or fname == '' then
    self:clear()
    return true
  end

  self.selectedFname = fname
  self.path = nil
  self.labels = {}
  self.error = nil

  local notebook = nil
  if isMetadataGhost(fname) then
    notebook = self:activeNotebook()
  else
    notebook = rallyUtil.loadNotebook(fname)
  end
  if not notebook then
    self.error = 'Could not load ghost notebook: ' .. tostring(fname)
    log('E', logTag, self.error)
    return false
  end

  self.path = notebook
  if notebook.refreshAllStructuredNotes then
    pcall(function() notebook:refreshAllStructuredNotes() end)
  end
  for _, pacenote in ipairs(notebook.pacenotes.sorted) do
    self.labels[pacenote.id] = labelForPacenote(pacenote)
  end
  return true
end

function C:getPath()
  return self.path
end

function C:getSelectedFname()
  return self.selectedFname
end

function C:getSelectedLabel()
  if not self.selectedFname then return '(none)' end
  return displayNameForFname(self.selectedFname)
end

function C:getError()
  return self.error
end

function C:getLabelForPacenote(pacenote)
  if not pacenote then return nil end
  if isMetadataGhost(self.selectedFname) then return calibrationMetadataLabel(pacenote) or '' end

  return self.labels[pacenote.id] or labelForPacenote(pacenote)
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
