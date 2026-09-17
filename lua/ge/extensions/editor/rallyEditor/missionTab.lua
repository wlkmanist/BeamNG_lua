-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local voicepack = require('/lua/ge/extensions/gameplay/rally/voicepack')

local im  = ui_imgui

local logTag = ''

local C = {}
C.windowDescription = 'Mission'

function C:init(rallyEditor)
  self.rallyEditor = rallyEditor
end

function C:setPath(path)
  self.path = path
end

function C:selected()
  extensions.hook("onEditorEditModeChanged", nil, nil)
end

function C:unselect()
  extensions.hook("onEditorEditModeChanged", nil, nil)
end

local function countOggFiles(dir)
  if not dir or not FS:directoryExists(dir) then return 0 end
  local files = FS:findFiles(dir, 'pacenote_*.ogg', 0, true, false)
  return files and #files or 0
end

local function missionExplorerTarget(missionDir)
  if not missionDir then return nil end
  local infoFile = missionDir..'/info.json'
  if FS:fileExists(infoFile) then return infoFile end
  local rallyDir = missionDir..'/rally'
  if FS:directoryExists(rallyDir) then return rallyDir end
  return missionDir
end

function C:draw(mouseInfo)
  local missionDir  = self.rallyEditor.getCurrentMissionDir()
  local missionName = self.rallyEditor.getCurrentMissionName()
  local missionId   = self.rallyEditor.getCurrentMissionId()

  im.HeaderText("Mission")

  if not missionDir then
    im.Text("No mission loaded. Open the Rally Editor from the Mission Editor.")
    return
  end

  im.Text("Name: "..tostring(missionName or '?'))
  im.Text("Id:   "..tostring(missionId or '?'))
  im.Text("Dir:  "..tostring(missionDir))
  im.SameLine()
  if editor.uiIconImageButton(editor.icons.folder_open, im.ImVec2(20, 20), im.ImVec4(1, 1, 1, 1)) then
    Engine.Platform.exploreFolder(missionExplorerTarget(missionDir))
  end
  im.tooltip("Open mission folder in explorer.")

  for _ = 1, 3 do im.Spacing() end
  im.Separator()
  im.HeaderText("Mission-local voicepacks")
  im.Text("Each entry below is a voicepack under <missionDir>/rally/voicepacks/<name>/.")
  im.Text("Its info.json declares which mission notebook(s) it pairs with.")
  for _ = 1, 2 do im.Spacing() end

  local pick = self.rallyEditor.getCurrentVoicepackPick()
  local missionVoicepacks = voicepack.scanMission(missionDir) or {}

  local sortedNames = {}
  for name, _ in pairs(missionVoicepacks) do table.insert(sortedNames, name) end
  table.sort(sortedNames)

  if #sortedNames == 0 then
    im.TextColored(im.ImVec4(0.7, 0.7, 0.7, 1.0), "(none in this mission)")
    return
  end

  for _, name in ipairs(sortedNames) do
    local entry = missionVoicepacks[name]
    local isCurrent = pick and pick.type == 'voicepack' and pick.scope == 'mission' and pick.dirname == name
    local label = name
    if isCurrent then
      im.TextColored(im.ImVec4(0.5, 1.0, 0.5, 1.0), "* "..label)
    else
      im.Text("  "..label)
    end

    local oggCount = countOggFiles(entry.dir)
    local notebooks = entry.notebooks and #entry.notebooks > 0 and table.concat(entry.notebooks, ', ') or '(default)'

    im.Indent()
    im.Text("Voicepack dir: "..tostring(entry.dir))
    if im.IsItemHovered() then im.tooltip(tostring(entry.dir)) end
    im.Text(string.format("Pacenote .ogg files: %d", oggCount))
    im.Text("Notebook precedence: "..notebooks)
    im.Unindent()

    im.Spacing()
  end
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
