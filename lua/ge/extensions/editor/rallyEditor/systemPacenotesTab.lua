-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local systemPacenotes = require('/lua/ge/extensions/gameplay/rally/notebook/systemPacenotes')

local C = {}
C.windowDescription = 'System Pacenotes'

function C:init(rallyEditor)
  self.rallyEditor = rallyEditor

  self.systemPacenotes = {}
  self.showSystemPacenotes = false
end

function C:clearState()
  self.path = nil
  self.systemPacenotes = {}
  self.showSystemPacenotes = false
end

-- this is the notebook. why am I still calling it a path???
function C:setPath(path)
  self.path = path

  -- Only show system pacenotes for rallyStage missions
  if path then
    local missionType = path:getMissionType()
    self.showSystemPacenotes = (missionType == "rallyStage")
  end
end

-- called by RallyEditor when this tab is selected.
function C:selected()
  if not self.path then return end

  if self.showSystemPacenotes then
    self.systemPacenotes = self.path:getSystemPacenotesForAudioMode()
  else
    self.systemPacenotes = {}
  end

  -- force redraw of shortcutLegend window
  extensions.hook("onEditorEditModeChanged", nil, nil)
end

-- called by RallyEditor when this tab is unselected.
function C:unselect()
  if not self.path then return end

  -- force redraw of shortcutLegend window
  extensions.hook("onEditorEditModeChanged", nil, nil)
end

local function orderedSystemPacenoteNames(pacenotesByName)
  local out = {}
  local seen = {}

  for _, name in ipairs(systemPacenotes.required) do
    if pacenotesByName[name] then
      table.insert(out, name)
      seen[name] = true
    end
  end

  local extras = {}
  for name in pairs(pacenotesByName) do
    if not seen[name] then
      table.insert(extras, name)
    end
  end
  table.sort(extras)

  for _, name in ipairs(extras) do
    table.insert(out, name)
  end

  return out
end

local function drawVariant(name, variantIndex, variant)
  im.Text(name..'_'..tostring(variantIndex))
  im.NextColumn()

  im.Text(tostring(variant.weight or 'auto'))
  im.NextColumn()

  im.Text(variant.text)
  im.NextColumn()

  local tooltipStr = ""
  local voicePlayClr = nil
  local audioFname = variant.audioFname
  local fileExists = audioFname and FS:fileExists(audioFname)

  if variant.isCustomAudio then
    if fileExists then
      voicePlayClr = im.ImVec4(0.5, 1.0, 0.5, 1.0)
      tooltipStr = "Custom audio:\n" .. audioFname
    else
      voicePlayClr = im.ImVec4(1.0, 0.5, 0.5, 1.0)
      tooltipStr = "Custom audio file not found:\n" .. tostring(audioFname)
    end
  elseif fileExists then
    tooltipStr = "Play pacenote audio file:\n" .. audioFname
  else
    voicePlayClr = im.ImVec4(0.5, 0.5, 0.5, 1.0)
    tooltipStr = "Pacenote audio file not found:\n" .. tostring(audioFname)
  end

  if editor.uiIconImageButton(editor.icons.play_circle_filled, im.ImVec2(20, 20), voicePlayClr) then
    if fileExists then
      Engine.Audio.intercomPlayPacenote({ filename = audioFname })
    end
  end
  im.tooltip(tooltipStr)
  im.NextColumn()
end

function C:draw(mouseInfo)
  if not self.path then return end

  im.HeaderText("System Pacenotes")
  im.Text("These are special pacenotes for internal use.")

  if not self.showSystemPacenotes then
    for _ = 1, 3 do im.Spacing() end
    im.TextColored(im.ImVec4(1.0, 1.0, 0.0, 1.0), "System Pacenotes are only available for rallyStage missions.")
    im.Text("Current mission type: " .. (self.path:getMissionType() or "unknown"))
    return
  end

  -- Refresh button to regenerate system pacenotes
  if im.Button("Refresh System Pacenotes") then
    -- Get the current compositor name before clearing
    local compositorName = nil
    if self.path.textCompositor then
      compositorName = self.path.textCompositor.compositorName
    end

    -- Clear ALL cached text compositor instances
    self.path.textCompositor = nil
    self.path.visualCompositor = nil
    self.path:clearCustomSystemPacenoteCache()

    -- Reload the compositor module to pick up any changes
    if compositorName then
      local compositorPath = '/lua/ge/extensions/gameplay/rally/compositors/styles/'..compositorName
      log('I', '', 'Reloading compositor module: '..compositorPath)
      package.loaded[compositorPath] = nil
    end

    -- Save notebook (regenerates system pacenotes) and reload
    self.path:save()
    self.systemPacenotes = self.path:getSystemPacenotesForAudioMode()
    log('I', '', 'System pacenotes refreshed')
  end
  im.tooltip("Save notebook and reload system pacenotes from disk")

  local tc = self.path:getTextCompositor()
  if tc then
    im.Text("Compositor: " .. tc.compositorName)
    im.tooltip("System pacenotes are loaded from:\n/lua/ge/extensions/gameplay/rally/compositors/styles/"..tc.compositorName..".lua")
  end

  for _ = 1, 5 do im.Spacing() end

  im.Columns(4, "spn_columns")
  im.Separator()

  im.Text("Name")
  im.NextColumn()

  im.Text("Weight")
  im.NextColumn()

  im.Text("Note Text")
  im.NextColumn()

  im.Text("Files")
  im.NextColumn()

  im.Separator()

  for _, name in ipairs(orderedSystemPacenoteNames(self.systemPacenotes)) do
    for i, variant in ipairs(self.systemPacenotes[name]) do
      drawVariant(name, i, variant)
    end
  end

  im.Columns(1)
  im.Separator()
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
