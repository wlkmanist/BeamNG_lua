-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local voicepack = require('/lua/ge/extensions/gameplay/rally/voicepack')
local TextCompositor = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/textCompositor')

local im  = ui_imgui

local logTag = ''

local clrOk = im.ImVec4(0.5, 1.0, 0.5, 1.0)
local clrBad = im.ImVec4(1.0, 0.35, 0.35, 1.0)
local clrMuted = im.ImVec4(0.7, 0.7, 0.7, 1.0)

local C = {}
C.windowDescription = 'Voicepacks'

function C:init(rallyEditor)
  self.rallyEditor = rallyEditor
  self.voicepackValidationCache = {}
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

local function trKey(key)
  if not key or key == '' then return nil end
  return _tr(key)
end

local function joinList(list, sep)
  if not list or #list == 0 then return '' end
  return table.concat(list, sep or ', ')
end

local function validationCacheKey(missionDir, entry)
  return string.format("%s|%s|%s", tostring(missionDir), tostring(entry and entry.dir), tostring(entry and entry.compositorStyle))
end

local function validateVoicepackAudio(self, missionDir, entry)
  if not entry then
    return { ok = false, error = 'missing voicepack entry', required = 0, missing = 0, missingFiles = {} }
  end

  local key = validationCacheKey(missionDir, entry)
  if self.voicepackValidationCache[key] then
    return self.voicepackValidationCache[key]
  end

  local result = {
    ok = false,
    required = 0,
    missing = 0,
    missingFiles = {},
  }

  if not entry.dir or entry.dir == '' then
    result.error = 'missing voicepack directory'
  elseif not entry.compositorStyle or entry.compositorStyle == '' then
    result.error = 'missing compositorStyle'
  else
    local compositor = TextCompositor(entry.compositorStyle, missionDir)
    if not compositor:load() then
      result.error = 'failed to load compositorStyle'
    else
      local ok, enumerated = pcall(function() return compositor:enumerateAll() end)
      if not ok then
        result.error = 'failed to enumerate required audio'
      else
        local metadata = voicepack.getEntryMetadata(entry) or {}
        for _, item in ipairs((enumerated and enumerated.phrases) or {}) do
          local audioFname = item.audioFname
          if not audioFname and item.group == 'system' and item.systemName then
            audioFname = rallyUtil.makeSystemPacenoteAudioFilename(item.systemName, item.systemVariantIndex)
          end
          audioFname = audioFname or rallyUtil.makePacenoteAudioFilename(item.hash or "")
          result.required = result.required + 1
          if #voicepack.getAudioCandidatesForEntry(entry, metadata, audioFname) == 0 then
            result.missing = result.missing + 1
            table.insert(result.missingFiles, audioFname)
          end
        end
        result.ok = result.missing == 0
      end
    end
  end

  self.voicepackValidationCache[key] = result
  return result
end

local function drawVoicepackAudioValidation(self, missionDir, entry)
  local validation = validateVoicepackAudio(self, missionDir, entry)
  if validation.error then
    im.TextColored(clrBad, "Audio files: validation failed ("..validation.error..")")
    return
  end

  local present = validation.required - validation.missing
  if validation.ok then
    im.TextColored(clrOk, string.format("Audio files: OK (%d/%d)", present, validation.required))
  else
    im.TextColored(clrBad, string.format("Audio files: missing %d/%d", validation.missing, validation.required))
    if im.IsItemHovered() and validation.missingFiles and #validation.missingFiles > 0 then
      im.BeginTooltip()
      im.Text("Missing required audio files:")
      for i, fname in ipairs(validation.missingFiles) do
        if i > 20 then
          im.Text(string.format("...and %d more", #validation.missingFiles - 20))
          break
        end
        im.Text(fname)
      end
      im.EndTooltip()
    end
  end
end

function C:drawPickers(missionDir)
  local pick    = self.rallyEditor.getCurrentVoicepackPick()
  local entries = voicepack.buildPickerEntries(missionDir, { missionSuffix = '(mission)' })

  local currentVpLabel = '(none)'
  for _, e in ipairs(entries) do
    if voicepack.picksMatch(e.pick, pick) then
      currentVpLabel = e.label
      break
    end
  end

  im.Text("Voicepack:")
  im.SameLine()
  im.SetNextItemWidth(320)
  if im.BeginCombo("##voicepackPickerTab", currentVpLabel) then
    if #entries == 0 then
      im.BeginDisabled()
      im.Selectable1("(no voicepacks resolve in this mission)", false)
      im.EndDisabled()
    else
      for _, e in ipairs(entries) do
        local isCurrent = voicepack.picksMatch(e.pick, pick)
        if im.Selectable1(e.label, isCurrent) and not isCurrent then
          self.rallyEditor.setVoicepackPick(e.pick)
        end
      end
    end
    im.EndCombo()
  end

  local notebookBasenames = voicepack.notebookBasenamesForPick(missionDir, pick)
  local currentBasename = '(none)'
  local cp = self.rallyEditor.getCurrentPath()
  if cp and cp.fname then
    currentBasename = (cp.fname:match("([^/\\]+)$") or cp.fname):gsub('%.notebook%.json$', '')
  end

  im.Text("Notebook:")
  im.SameLine()
  im.SetNextItemWidth(280)
  if im.BeginCombo("##notebookPickerTab", currentBasename) then
    if #notebookBasenames == 0 then
      im.BeginDisabled()
      im.Selectable1("(no notebooks for this voicepack)", false)
      im.EndDisabled()
    else
      for _, basename in ipairs(notebookBasenames) do
        local isSelected = basename == currentBasename
        if im.Selectable1(basename, isSelected) and not isSelected then
          self.rallyEditor.loadNotebook(rallyUtil.getNotebookFullPath(missionDir, basename..'.notebook.json'))
        end
      end
    end
    im.EndCombo()
  end
end

local function drawVoicepackList(self, missionDir, scope, index)
  local pick = self.rallyEditor.getCurrentVoicepackPick()

  local sortedDirs = {}
  for dirname, _ in pairs(index) do table.insert(sortedDirs, dirname) end
  table.sort(sortedDirs)

  if #sortedDirs == 0 then
    if scope == 'global' then
      im.TextColored(clrMuted, "(no global voicepacks installed)")
    else
      im.TextColored(clrMuted, "(none in this mission)")
    end
    return
  end

  for _, dirname in ipairs(sortedDirs) do
    local entry     = index[dirname]
    local isCurrent = pick and pick.type == 'voicepack' and pick.dirname == dirname
                      and (pick.scope or 'global') == scope
    local validation = validateVoicepackAudio(self, missionDir, entry)
    local nameColor = validation.ok and clrOk or clrBad
    local prefix = isCurrent and "* " or "  "

    im.TextColored(nameColor, prefix..dirname)

    im.Indent()
    local persona  = trKey(entry.persona)    or '?'
    local language = trKey(entry.language)   or '?'
    local dialect  = trKey(entry.dialect)
    local styleLbl = trKey(entry.styleLabel) or '?'

    if dialect and dialect ~= '' then
      im.Text(string.format("Persona: %s   Language: %s (%s)   Style: %s", persona, language, dialect, styleLbl))
    else
      im.Text(string.format("Persona: %s   Language: %s   Style: %s", persona, language, styleLbl))
    end
    im.Text("Compositor style: "..tostring(entry.compositorStyle or '(none, pre-recorded)'))
    im.Text("Voicepack dir: "..tostring(entry.dir or '?'))
    drawVoicepackAudioValidation(self, missionDir, entry)

    local precedence = entry.notebooks or {}
    im.Text("Notebook precedence: "..joinList(precedence))

    local resolved = voicepack.listMissionNotebookCandidates(missionDir, entry) or {}
    local resolvedStr = #resolved > 0 and joinList(resolved) or '(none)'
    im.Text("Resolves in this mission: "..resolvedStr)
    im.Unindent()

    im.Spacing()
  end
end

function C:drawGlobalVoicepacks(missionDir)
  im.HeaderText("Global voicepacks")
  im.Text("Voicepacks shipped with the game / mods. Each lists its style and which of its candidate notebooks resolve in this mission.")
  for _ = 1, 2 do im.Spacing() end
  drawVoicepackList(self, missionDir, 'global', voicepack.scan() or {})
end

function C:drawMissionLocalVoicepacks(missionDir)
  im.HeaderText("Mission-local voicepacks")
  im.Text("Voicepacks under <missionDir>/rally/voicepacks/<name>/. Same shape as global voicepacks; their info.json declares which mission notebook(s) they pair with.")
  for _ = 1, 2 do im.Spacing() end
  drawVoicepackList(self, missionDir, 'mission', voicepack.scanMission(missionDir) or {})
end

function C:draw(mouseInfo)
  local missionDir = self.rallyEditor.getCurrentMissionDir()

  im.HeaderText("Voicepacks")

  if not missionDir then
    im.Text("No mission loaded. Open the Rally Editor from the Mission Editor.")
    return
  end

  if im.Button("Refresh voicepacks") then
    voicepack.invalidateCache()
    voicepack.invalidateMissionCache(missionDir)
    self.voicepackValidationCache = {}
  end

  for _ = 1, 2 do im.Spacing() end

  self:drawPickers(missionDir)

  for _ = 1, 3 do im.Spacing() end
  im.Separator()
  self:drawGlobalVoicepacks(missionDir)

  for _ = 1, 3 do im.Spacing() end
  im.Separator()
  self:drawMissionLocalVoicepacks(missionDir)
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
