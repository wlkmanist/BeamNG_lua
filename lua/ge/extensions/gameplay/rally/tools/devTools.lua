-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local DrivelineRoute = require('/lua/ge/extensions/gameplay/rally/driveline/drivelineRoute')
local TextCompositor = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/textCompositor')
local PacenoteGenerator = require('/lua/ge/extensions/gameplay/rally/notebook/pacenoteGenerator')
local TrafficExclusion = require('/lua/ge/extensions/gameplay/rally/trafficExclusion')
local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local voicepack = require('/lua/ge/extensions/gameplay/rally/voicepack')

local logTag = ''

local C = {}

function C:init()
  -- self:_reset()
  self:loadCompositors()

  -- Pacenotes Tools state
  self.pacenotesTools = {
    elevationProfile = nil,
    elevationProfileInfo = nil,
    showElevationProfilePoints = false,
    drivelinePoints = nil,
    showDrivelinePoints = false,
    sections = nil,
    corners = nil,
    -- Corner detection parameters (matched with PacenoteGenerator.defaultParams)
    params = {
      lookAheadContext = im.IntPtr(PacenoteGenerator.defaultParams.lookAheadContext),
      straightThreshold = im.FloatPtr(PacenoteGenerator.defaultParams.straightThreshold),
      mergeDistanceThreshold = im.FloatPtr(PacenoteGenerator.defaultParams.mergeDistanceThreshold),
      maxSimplifyIterations = im.IntPtr(PacenoteGenerator.defaultParams.maxSimplifyIterations)
    }
  }

  -- Traffic exclusion state
  self.trafficTools = {
    zoneRadius = im.FloatPtr(10.0),
    zones = nil,
    showZones = true,
    -- RallyLoop dropdown state
    rallyLoopMissions = {"<none>"},
    selectedRallyLoopIndex = im.IntPtr(0),
    selectedRallyLoopId = nil
  }
end

-- function C:_reset()
  -- self.reachedPacenotes = {}
  -- self.selectedWaypoint = nil
  -- self.drivelineRoute = DrivelineRoute()
-- end

-- function C:loadRoute()
--   if not editor_raceEditor then
--     log('E', 'Rally Debug', 'No race editor found')
--     return
--   end

--   local racePath = editor_raceEditor.getCurrentPath()
--   if not racePath then
--     log('E', 'Rally Debug', 'No race path found')
--     return
--   end

--   if not editor_rallyEditor then
--     log('E', 'Rally Debug', 'No rally editor found')
--     return
--   end

--   local notebookPath = editor_rallyEditor.getCurrentPath()
--   if not notebookPath then
--     log('E', 'Rally Debug', 'No notebook path found')
--     return
--   end

--   if self.drivelineRoute then
--     self.drivelineRoute:loadRoute(racePath, notebookPath)
--   else
--     log('E', 'Rally Debug', 'No driveline route found')
--   end
-- end

function C:loadCompositors()
  local compositorFiles = FS:findFiles("/lua/ge/extensions/gameplay/rally/compositors/styles/", "*.lua", -1, true, false)
  local compositors = {}
  local groupsById = {}
  local checked = self.compositorChecked or {}

  local function looksLikeCompositor(compositorName)
    local ok, style = pcall(require, '/lua/ge/extensions/gameplay/rally/compositors/styles/'..compositorName)
    return ok and type(style) == 'table'
       and type(style.distance) == 'table'
       and type(style.componentTypes) == 'table'
       and type(style.system) == 'table'
       and type(style.composite) == 'function'
       and type(style.enumerate) == 'function'
  end

  for _, file in ipairs(compositorFiles) do
    local compositorName = string.match(file, "/compositors/styles/(.+)%.lua$")
    if compositorName and looksLikeCompositor(compositorName) then
      local compositor = TextCompositor(compositorName)
      if compositor:load() then
        table.insert(compositors, compositorName)
      end
    end
  end

  table.sort(compositors)
  for _, compositorName in ipairs(compositors) do
    if checked[compositorName] == nil then
      checked[compositorName] = false
    end

    local groupId = string.match(compositorName, "^([^/]+)") or "other"
    local group = groupsById[groupId]
    if not group then
      group = { id = groupId, label = "styles/"..groupId, items = {} }
      groupsById[groupId] = group
    end
    table.insert(group.items, compositorName)
  end

  local groupIds = {}
  for id in pairs(groupsById) do table.insert(groupIds, id) end
  table.sort(groupIds)

  local groups = {}
  for _, id in ipairs(groupIds) do
    local group = groupsById[id]
    table.sort(group.items)
    table.insert(groups, group)
  end

  log('I', logTag, 'loaded textCompositors: ' .. dumps(compositors))
  self.compositors = compositors
  self.compositorGroups = groups
  self.compositorChecked = checked
  if not self.selectedSkeletonCompositor and compositors[1] then
    self.selectedSkeletonCompositor = compositors[1]
  end
end

local function styleLeaf(compositorName)
  return string.match(compositorName or '', "([^/]+)$") or tostring(compositorName)
end

local function addUnique(list, value)
  if not value then return end
  for _, existing in ipairs(list) do
    if existing == value then return end
  end
  table.insert(list, value)
  table.sort(list)
end

local function styleSlug(compositorName)
  return string.gsub(compositorName or '', '/', '_')
end

local function styleLabelSlug(compositorName)
  return (compositorName or ''):match("([^/\\]+)$") or ''
end

function C:voicepackSkeletonOutDir()
  if not self.selectedSkeletonCompositor then return '' end
  return string.format('/temp/rally/voicepack_%s', styleSlug(self.selectedSkeletonCompositor))
end

function C:generateVoicepackSkeleton()
  local selectedCompositor = self.selectedSkeletonCompositor
  if not selectedCompositor or selectedCompositor == '' then
    log('E', logTag, 'No text compositor selected for voicepack skeleton')
    return
  end

  local compositor = TextCompositor(selectedCompositor)
  if not compositor:load() then
    log('E', logTag, 'failed to load text compositor: '..tostring(selectedCompositor))
    return
  end

  local outDir = self:voicepackSkeletonOutDir()
  if outDir == '' then return end

  if FS:directoryExists(outDir) then
    for _, f in ipairs(FS:findFiles(outDir, '*', -1, true, false) or {}) do
      FS:remove(f)
    end
    FS:directoryRemove(outDir)
  end
  FS:directoryCreate(outDir, true)
  FS:directoryCreate(outDir..'/'..voicepack.audioSubdir, true)

  local infoFname = outDir..'/'..voicepack.infoBasename
  local metadataFname = outDir..'/'..rallyUtil.pacenotesMetadataBasename

  local info = {
    persona = "",
    language = "",
    dialect = "",
    style = selectedCompositor,
    styleLabel = "ui.options.rally.styles."..styleLabelSlug(selectedCompositor)..".name",
  }
  jsonWriteFile(infoFname, info, true)

  jsonWriteFile(metadataFname, {}, true)

  log('I', logTag, 'Voicepack skeleton written to: '..outDir)
  Engine.Platform.exploreFolder(outDir)
end

function C:selectedCompositors()
  local selected = {}
  for _, compositorName in ipairs(self.compositors or {}) do
    if self.compositorChecked and self.compositorChecked[compositorName] then
      table.insert(selected, compositorName)
    end
  end

  return selected
end

function C:recordingCoverageEntries()
  local selected = self:selectedCompositors()
  if #selected == 0 then
    return {}, selected
  end

  local byFilename = {}
  for _, compositorName in ipairs(selected) do
    local compositor = TextCompositor(compositorName)
    if compositor:load() then
      for _, entry in ipairs(compositor:enumerateScriptEntries() or {}) do
        local key = entry.audioFname
        if key and key ~= '' then
          local merged = byFilename[key]
          if not merged then
            merged = deepcopy(entry)
            merged.styles = {}
            merged.sourceContexts = {}
            byFilename[key] = merged
          end
          addUnique(merged.styles, compositorName)
          addUnique(merged.sourceContexts, entry.sourceContext)
        end
      end
    else
      log('E', logTag, 'failed to load text compositor: '..tostring(compositorName))
    end
  end

  local entries = {}
  for _, entry in pairs(byFilename) do
    table.insert(entries, entry)
  end

  table.sort(entries, function(a, b)
    if (a.sortGroup or 999) ~= (b.sortGroup or 999) then return (a.sortGroup or 999) < (b.sortGroup or 999) end
    if (a.sortSubgroup or a.subcategory or '') ~= (b.sortSubgroup or b.subcategory or '') then
      return (a.sortSubgroup or a.subcategory or '') < (b.sortSubgroup or b.subcategory or '')
    end
    if (a.subcategory or '') ~= (b.subcategory or '') then return (a.subcategory or '') < (b.subcategory or '') end
    if (a.phrase or '') ~= (b.phrase or '') then return (a.phrase or '') < (b.phrase or '') end
    if (a.sourceContext or '') ~= (b.sourceContext or '') then return (a.sourceContext or '') < (b.sourceContext or '') end
    return (a.audioFname or '') < (b.audioFname or '')
  end)

  for i, entry in ipairs(entries) do
    entry.order = i
  end

  return entries, selected
end

function C:enumerate()
  self:exportScriptReaderHtml()
end

local function buildScriptNavigation(entries)
  local nav = { groups = {} }
  local groupByKey = {}

  local function getGroup(entry, index)
    local key = entry.category or '?'
    local group = groupByKey[key]
    if not group then
      group = { key = key, label = key, firstIndex = index, count = 0, children = {}, childByKey = {} }
      groupByKey[key] = group
      table.insert(nav.groups, group)
    end
    group.count = group.count + 1
    return group
  end

  local function getChild(group, entry, index)
    local key = entry.subcategory or ''
    local label = key ~= '' and key or group.label
    local child = group.childByKey[key]
    if not child then
      child = { key = key, label = label, firstIndex = index, count = 0, entries = {} }
      group.childByKey[key] = child
      table.insert(group.children, child)
    end
    child.count = child.count + 1
    return child
  end

  for index, entry in ipairs(entries or {}) do
    local group = getGroup(entry, index)
    local child = getChild(group, entry, index)
    table.insert(child.entries, {
      index = index,
      phrase = entry.phrase or '',
      variant = entry.variant,
    })
  end

  return nav
end

local function cleanScriptNavigation(nav)
  local out = { groups = {} }
  for _, group in ipairs(nav.groups or {}) do
    local cleanGroup = {
      key = group.key,
      label = group.label,
      firstIndex = group.firstIndex,
      count = group.count,
      children = {},
    }
    for _, child in ipairs(group.children or {}) do
      local cleanChild = {
        key = child.key,
        label = child.label,
        firstIndex = child.firstIndex,
        count = child.count,
        entries = {},
      }
      for _, entry in ipairs(child.entries or {}) do
        table.insert(cleanChild.entries, {
          index = entry.index,
          phrase = entry.phrase,
          variant = entry.variant,
        })
      end
      table.insert(cleanGroup.children, cleanChild)
    end
    table.insert(out.groups, cleanGroup)
  end
  return out
end

local function scriptReaderCopyValue(entry)
  if not entry then return "" end

  if entry.recordingSlug and entry.recordingSlug ~= '' then
    return entry.recordingSlug
  end

  return entry.hash or ""
end

local function scriptReaderTextFingerprint(entries)
  local phrases = {}
  for i, entry in ipairs(entries or {}) do
    if type(entry.phrase) ~= 'string' then
      return nil, 'Recording script entry '..tostring(i)..' is missing a valid phrase'
    end

    if rallyUtil.trimString(entry.phrase) == '' then
      return nil, 'Recording script entry '..tostring(i)..' has an empty phrase'
    end

    table.insert(phrases, entry.phrase)
  end

  table.sort(phrases)

  local ok, encoded = pcall(jsonEncode, phrases)
  if not ok or not encoded then
    return nil, 'failed to encode recording script fingerprint data'
  end

  return hashStringSHA1(encoded)
end

local function scriptReaderExportData(sm)
  local entries = {}
  for _, entry in ipairs(sm.entries or {}) do
    table.insert(entries, {
      order = entry.order,
      phrase = entry.phrase,
      hash = entry.hash,
      recordingSlug = entry.recordingSlug,
      copyValue = scriptReaderCopyValue(entry),
      category = entry.category,
      subcategory = entry.subcategory,
      sourceContexts = entry.sourceContexts or {},
      variant = entry.variant,
      audioFname = entry.audioFname,
      styles = entry.styles or {},
    })
  end

  local textFingerprint, fingerprintErr = scriptReaderTextFingerprint(entries)
  if not textFingerprint then
    return nil, fingerprintErr
  end

  return {
    generatedAt = os.date("%Y-%m-%d %H:%M:%S"),
    selectedStyles = sm.selectedStyles or {},
    textFingerprint = textFingerprint,
    entries = entries,
    nav = cleanScriptNavigation(buildScriptNavigation(entries)),
  }
end

local function scriptReaderTxt(exportData)
  local lines = {}
  for _, entry in ipairs(exportData.entries or {}) do
    table.insert(lines, entry.phrase or '')
  end

  return table.concat(lines, '\n')..'\n'
end

local function encodeJsonForHtml(data)
  local ok, encoded = pcall(jsonEncode, data)
  if not ok or not encoded then
    return nil
  end
  return encoded:gsub("</", "<\\/")
end

local scriptReaderLogoPngPath = '/lua/ge/extensions/gameplay/rally/tools/logo.png'

local function scriptReaderLogoDataUrl()
  if not FS:fileExists(scriptReaderLogoPngPath) then
    log('W', logTag, 'Recording script logo not found: '..scriptReaderLogoPngPath)
    return ''
  end

  local png = readFile(scriptReaderLogoPngPath)
  if not png or png == '' then
    log('W', logTag, 'Recording script logo is empty: '..scriptReaderLogoPngPath)
    return ''
  end

  local encoded = mime.b64(png)
  if not encoded or encoded == '' then
    log('W', logTag, 'Failed to base64 encode recording script logo: '..scriptReaderLogoPngPath)
    return ''
  end

  return 'data:image/png;base64,'..encoded
end

local function scriptReaderHtml(data, logoDataUrl)
  local encoded = encodeJsonForHtml(data)
  if not encoded then return nil end
  logoDataUrl = logoDataUrl or ''

  local prefix = [===[<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>BeamNG.drive Voicepack Recording Script</title>
<style>
:root {
  color-scheme: dark;
  --bg: #0d1015;
  --panel: #171c24;
  --panel-2: #202733;
  --panel-3: #11151c;
  --text: #f4f1ec;
  --muted: #a7afbc;
  --accent: #ff7a1a;
  --accent-soft: rgba(255, 122, 26, 0.16);
  --border: #303846;
  --logo-tile: #f4efe7;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  background: var(--bg);
  color: var(--text);
}
.app {
  max-width: 1320px;
  margin: 0 auto;
  padding: 24px;
}
.header, .reader, .tips {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 16px;
  margin-bottom: 16px;
}
.header {
  display: flex;
  gap: 24px;
  align-items: stretch;
  justify-content: space-between;
  min-height: 104px;
  overflow: hidden;
  color: var(--text);
  background: var(--panel);
  border: 3px solid var(--accent);
  box-shadow: 0 0 24px rgba(255, 122, 26, 0.24);
}
.reader {
  position: relative;
  box-shadow: inset 0 1px 0 var(--accent-soft);
}
.header-copy {
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  justify-content: center;
  min-width: 0;
}
.brand-logo {
  display: flex;
  flex: 0 0 auto;
  align-items: center;
  justify-content: center;
  max-width: 34%;
  padding: 10px 14px;
  border: 1px solid rgba(255, 122, 26, 0.26);
  border-radius: 10px;
  background: var(--logo-tile);
}
.brand-logo img {
  display: block;
  width: auto;
  height: 100%;
  max-height: 78px;
  object-fit: contain;
}
.header h1 {
  margin: 0;
  font-size: 24px;
  line-height: 1.15;
}
.muted { color: var(--muted); }
.header .muted { color: #c4cad3; }
.fingerprint {
  margin-top: 6px;
}
.fingerprint-value {
  color: var(--accent);
  font-family: ui-monospace, SFMono-Regular, Consolas, "Liberation Mono", monospace;
  font-weight: 700;
  overflow-wrap: anywhere;
}
.layout {
  display: grid;
  grid-template-columns: 340px minmax(0, 1fr);
  gap: 16px;
}
.nav {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 12px;
  max-height: calc(100vh - 220px);
  overflow: auto;
}
details { margin: 4px 0; }
summary {
  cursor: pointer;
  color: var(--accent);
  padding: 4px 0;
}
.nav-group > summary {
  font-weight: 700;
}
.nav-child > summary {
  color: var(--text);
}
.nav-children {
  margin-left: 14px;
  padding-left: 10px;
  border-left: 1px solid var(--border);
}
.nav-lines {
  margin-left: 14px;
  padding-left: 10px;
  border-left: 1px solid var(--border);
}
.nav-line {
  width: 100%;
  display: block;
  text-align: left;
  margin: 2px 0;
  padding: 5px 8px;
  border: 0;
  border-radius: 6px;
  background: transparent;
  color: var(--text);
  cursor: pointer;
}
.nav-line:hover, .nav-line.active {
  background: var(--panel-2);
  color: var(--accent);
}
.meta-row {
  display: flex;
  gap: 10px;
  align-items: baseline;
  flex-wrap: wrap;
}
.category { color: var(--accent); font-weight: 650; }
.variant { color: var(--accent); font-weight: 650; }
.progress-row {
  display: flex;
  gap: 10px;
  align-items: center;
  margin: 10px 0 14px;
}
.progress-bar {
  position: relative;
  flex: 1;
  height: 10px;
  overflow: hidden;
  border-radius: 999px;
  background: var(--panel-2);
  border: 1px solid var(--border);
}
.progress-fill {
  width: 0%;
  height: 100%;
  border-radius: inherit;
  background: var(--accent);
  transition: width 160ms ease;
}
.progress-label {
  min-width: 42px;
  text-align: right;
  font-variant-numeric: tabular-nums;
}
.halfway-celebration {
  position: fixed;
  inset: 0;
  z-index: 4;
  pointer-events: none;
  opacity: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  transform: scale(0.98);
}
.halfway-celebration.show {
  animation: halfway-pop 2200ms ease-out forwards;
}
.halfway-card {
  position: relative;
  z-index: 2;
  padding: 14px 20px;
  border: 2px solid var(--accent);
  border-radius: 14px;
  background: #10141b;
  box-shadow: 0 0 34px rgba(255, 122, 26, 0.36);
  color: var(--text);
  font-weight: 800;
  font-size: 20px;
  letter-spacing: 0.01em;
}
.confetti {
  position: absolute;
  left: 50%;
  top: 50%;
  width: 10px;
  height: 18px;
  border-radius: 2px;
  background: var(--accent);
  opacity: 0;
}
.halfway-celebration.show .confetti {
  animation: confetti-burst 1500ms ease-out forwards;
}
.confetti:nth-child(1) { --x: -44vw; --y: -20vh; --r: -180deg; background: #ff7a1a; }
.confetti:nth-child(2) { --x: -36vw; --y: -34vh; --r: 210deg; background: #f4f1ec; animation-delay: 30ms; }
.confetti:nth-child(3) { --x: -24vw; --y: -40vh; --r: 150deg; background: #ffb15c; animation-delay: 60ms; }
.confetti:nth-child(4) { --x: -8vw; --y: -43vh; --r: -240deg; background: #ff7a1a; animation-delay: 20ms; }
.confetti:nth-child(5) { --x: 10vw; --y: -42vh; --r: 190deg; background: #f4f1ec; animation-delay: 80ms; }
.confetti:nth-child(6) { --x: 27vw; --y: -36vh; --r: -160deg; background: #ffb15c; animation-delay: 45ms; }
.confetti:nth-child(7) { --x: 40vw; --y: -23vh; --r: 220deg; background: #ff7a1a; animation-delay: 90ms; }
.confetti:nth-child(8) { --x: 45vw; --y: -4vh; --r: -210deg; background: #f4f1ec; animation-delay: 55ms; }
.confetti:nth-child(9) { --x: 38vw; --y: 16vh; --r: 170deg; background: #ffb15c; animation-delay: 105ms; }
.confetti:nth-child(10) { --x: 24vw; --y: 31vh; --r: -190deg; background: #ff7a1a; animation-delay: 75ms; }
.confetti:nth-child(11) { --x: 7vw; --y: 40vh; --r: 250deg; background: #f4f1ec; animation-delay: 120ms; }
.confetti:nth-child(12) { --x: -12vw; --y: 38vh; --r: -230deg; background: #ffb15c; animation-delay: 35ms; }
.confetti:nth-child(13) { --x: -29vw; --y: 28vh; --r: 185deg; background: #ff7a1a; animation-delay: 95ms; }
.confetti:nth-child(14) { --x: -42vw; --y: 10vh; --r: -150deg; background: #f4f1ec; animation-delay: 65ms; }
.confetti:nth-child(15) { --x: -48vw; --y: -6vh; --r: 205deg; background: #ffb15c; animation-delay: 110ms; }
.confetti:nth-child(16) { --x: 0vw; --y: -32vh; --r: -175deg; background: #ff7a1a; animation-delay: 130ms; }
.confetti:nth-child(17) { --x: 31vw; --y: 4vh; --r: 230deg; background: #f4f1ec; animation-delay: 15ms; }
.confetti:nth-child(18) { --x: -33vw; --y: -4vh; --r: -220deg; background: #ffb15c; animation-delay: 140ms; }
@keyframes halfway-pop {
  0% { opacity: 0; transform: scale(0.98); }
  10% { opacity: 1; transform: scale(1.02); }
  22% { transform: scale(1); }
  76% { opacity: 1; transform: scale(1); }
  100% { opacity: 0; transform: scale(1.01); }
}
@keyframes confetti-burst {
  0% { opacity: 0; transform: translate(-50%, -50%) scale(0.4) rotate(0deg); }
  10% { opacity: 1; }
  100% { opacity: 0; transform: translate(calc(-50% + var(--x)), calc(-50% + var(--y))) scale(1.2) rotate(var(--r)); }
}
.phrase {
  --phrase-size: 56px;
  font-size: var(--phrase-size);
  line-height: 1.05;
  font-weight: 620;
  margin: 28px 0;
}
.filename {
  color: var(--accent);
  font-family: ui-monospace, SFMono-Regular, Consolas, "Liberation Mono", monospace;
}
.recording-targets {
  display: grid;
  gap: 8px;
}
.target-row {
  display: flex;
  gap: 8px;
  align-items: center;
  flex-wrap: wrap;
}
.target-label {
  color: var(--muted);
}
button {
  background: var(--panel-2);
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 7px 11px;
  cursor: pointer;
}
button:hover {
  border-color: var(--accent);
  background: #252d39;
}
.controls {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  margin-top: 18px;
}
.tips summary {
  font-weight: 700;
}
.tips ul { margin: 8px 0 0 20px; padding: 0; }
.tips li { margin: 4px 0; }
@media (max-width: 820px) {
  .header { flex-direction: column; }
  .brand-logo { max-width: none; align-self: flex-start; }
  .layout { grid-template-columns: 1fr; }
  .nav { max-height: 280px; }
}
</style>
</head>
<body>
<div class="app">
  <section class="header">
    <div class="header-copy">
      <h1>BeamNG.drive Voicepack Recording Script</h1>
      <div class="muted" id="summary"></div>
      <div class="muted fingerprint">Script fingerprint: <span class="fingerprint-value" id="textFingerprint"></span></div>
    </div>
]===]..(logoDataUrl ~= '' and '    <div class="brand-logo"><img src="'..logoDataUrl..'" alt="BeamNG.drive logo"></div>\n' or '')..[===[
  </section>
  <div class="layout">
    <nav class="nav">
      <strong>Jump to phrase</strong>
      <div id="navTree"></div>
    </nav>
    <main>
      <section class="reader">
        <div class="meta-row">
          <span id="position"></span>
        </div>
        <div class="progress-row">
          <div class="progress-bar" id="progressBar" role="progressbar" aria-label="Recording progress" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0">
            <div class="progress-fill" id="progressFill"></div>
          </div>
          <span class="muted progress-label" id="progressLabel"></span>
        </div>
        <div class="halfway-celebration" id="halfwayCelebration" aria-live="polite" hidden>
          <span class="confetti"></span><span class="confetti"></span><span class="confetti"></span><span class="confetti"></span><span class="confetti"></span>
          <span class="confetti"></span><span class="confetti"></span><span class="confetti"></span><span class="confetti"></span><span class="confetti"></span>
          <span class="confetti"></span><span class="confetti"></span><span class="confetti"></span><span class="confetti"></span><span class="confetti"></span>
          <span class="confetti"></span><span class="confetti"></span><span class="confetti"></span>
          <div class="halfway-card">Halfway there!</div>
        </div>
        <div class="meta-row">
          <span class="category" id="category"></span>
          <span class="variant" id="variant" hidden></span>
          <span class="muted" id="sourceContext"></span>
        </div>
        <div class="controls">
          <button id="fontSmallerButton" type="button">A-</button>
          <button id="fontLargerButton" type="button">A+</button>
        </div>
        <div class="phrase" id="phrase"></div>
        <div class="recording-targets">
          <div class="target-row">
            <span class="target-label">Phrase ID:</span>
            <span class="filename" id="phraseId"></span>
            <button id="copyIdButton" type="button">Copy ID</button>
          </div>
          <div class="target-row">
            <span class="target-label">Save recording as:</span>
            <span class="filename" id="filename"></span>
            <button id="copyFilenameButton" type="button">Copy Filename</button>
          </div>
          <div class="target-row">
            <span class="target-label">Recording slug:</span>
            <span class="filename" id="recordingSlug"></span>
            <button id="copySlugButton" type="button">Copy Slug</button>
          </div>
        </div>
        <div class="muted" id="styles"></div>
        <div class="controls">
          <button id="firstButton" type="button">|&lt; First</button>
          <button id="backButton" type="button">&lt; Back</button>
          <button id="nextButton" type="button">Next &gt;</button>
          <button id="nextCopyButton" type="button">Next &amp; Copy Slug</button>
          <button id="endButton" type="button">End &gt;|</button>
        </div>
      </section>
      <details class="tips">
        <summary>Recording tips</summary>
        <ul>
          <li>Record in a quiet room. Keep a consistent distance from the mic.</li>
          <li>Keep tone and energy consistent across the whole script so phrases blend together.</li>
          <li>Deliver phrases like a real co-driver.</li>
          <li>You can do as many takes as you want for each phrase. If you stumble mid-phrase, just try again.</li>
          <li>Leave a bit of silence before and after each phrase for clean trimming.</li>
          <li>Name each clip exactly as the displayed target filename.</li>
          <li>Keyboard shortcuts: Left/Right arrows move between phrases. Home/End jump to first/last.</li>
        </ul>
      </details>
    </main>
  </div>
</div>
<script id="scriptData" type="application/json">
]===]

  local suffix = [===[
</script>
<script>
const data = JSON.parse(document.getElementById('scriptData').textContent);
const entries = data.entries || [];
let index = 0;
let phraseSize = 56;
let shouldCelebrateHalfway = false;
let halfwayCelebrationTimer = null;

const els = {
  summary: document.getElementById('summary'),
  textFingerprint: document.getElementById('textFingerprint'),
  navTree: document.getElementById('navTree'),
  position: document.getElementById('position'),
  progressBar: document.getElementById('progressBar'),
  progressFill: document.getElementById('progressFill'),
  progressLabel: document.getElementById('progressLabel'),
  halfwayCelebration: document.getElementById('halfwayCelebration'),
  category: document.getElementById('category'),
  variant: document.getElementById('variant'),
  sourceContext: document.getElementById('sourceContext'),
  phrase: document.getElementById('phrase'),
  filename: document.getElementById('filename'),
  recordingSlug: document.getElementById('recordingSlug'),
  phraseId: document.getElementById('phraseId'),
  copyFilenameButton: document.getElementById('copyFilenameButton'),
  copySlugButton: document.getElementById('copySlugButton'),
  copyIdButton: document.getElementById('copyIdButton'),
  styles: document.getElementById('styles'),
};

function categoryLabel(entry) {
  return entry.subcategory ? `${entry.category || '?'} / ${entry.subcategory}` : (entry.category || '?');
}

function applyPhraseSize() {
  els.phrase.style.setProperty('--phrase-size', `${phraseSize}px`);
}

function adjustPhraseSize(delta) {
  phraseSize = Math.max(28, Math.min(96, phraseSize + delta));
  applyPhraseSize();
}

function triggerHalfwayCelebration() {
  els.halfwayCelebration.hidden = false;
  els.halfwayCelebration.classList.remove('show');
  void els.halfwayCelebration.offsetWidth;
  els.halfwayCelebration.classList.add('show');
  window.clearTimeout(halfwayCelebrationTimer);
  halfwayCelebrationTimer = window.setTimeout(() => {
    els.halfwayCelebration.classList.remove('show');
    els.halfwayCelebration.hidden = true;
  }, 2200);
}

function progressForIndex(entryIndex) {
  return entries.length ? Math.round(((entryIndex + 1) / entries.length) * 100) : 0;
}

function go(nextIndex, scrollNav = true, celebrateNextHalfway = false) {
  if (!entries.length) return;
  const oldProgress = progressForIndex(index);
  index = Math.max(0, Math.min(nextIndex, entries.length - 1));
  const newProgress = progressForIndex(index);
  shouldCelebrateHalfway = celebrateNextHalfway && oldProgress === 49 && newProgress === 50;
  renderEntry();
  if (scrollNav) {
    const active = document.querySelector('.nav-line.active');
    if (active) active.scrollIntoView({ block: 'nearest' });
  }
}

function renderNav() {
  els.navTree.replaceChildren();
  (data.nav?.groups || []).forEach(group => {
    const groupDetails = document.createElement('details');
    groupDetails.className = 'nav-group';
    const groupSummary = document.createElement('summary');
    groupSummary.textContent = `${group.label} (${group.count})`;
    groupDetails.appendChild(groupSummary);
    const childContainer = document.createElement('div');
    childContainer.className = 'nav-children';

    (group.children || []).forEach(child => {
      const childDetails = document.createElement('details');
      childDetails.className = 'nav-child';
      const childSummary = document.createElement('summary');
      childSummary.textContent = `${child.label} (${child.count})`;
      childDetails.appendChild(childSummary);
      const lineContainer = document.createElement('div');
      lineContainer.className = 'nav-lines';

      (child.entries || []).forEach(item => {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'nav-line';
        button.dataset.index = String(item.index - 1);
        button.textContent = item.phrase || '(blank phrase)';
        button.addEventListener('click', () => go(item.index - 1, false));
        lineContainer.appendChild(button);
      });

      childDetails.appendChild(lineContainer);
      childContainer.appendChild(childDetails);
    });

    groupDetails.appendChild(childContainer);
    els.navTree.appendChild(groupDetails);
  });
}

function renderEntry() {
  const entry = entries[index];
  if (!entry) return;

  const progress = progressForIndex(index);
  const targetFilename = entry.audioFname || '';
  const recordingSlug = entry.copyValue || '';
  const phraseId = entry.order || index + 1;
  if (shouldCelebrateHalfway) {
    triggerHalfwayCelebration();
  }
  shouldCelebrateHalfway = false;
  els.position.textContent = `${index + 1} of ${entries.length} phrases`;
  els.progressBar.setAttribute('aria-valuenow', String(progress));
  els.progressFill.style.width = `${progress}%`;
  els.progressLabel.textContent = `${progress}%`;
  els.category.textContent = categoryLabel(entry);
  els.variant.textContent = entry.variant ? `Variant: ${entry.variant}` : '';
  els.variant.hidden = !entry.variant;
  els.sourceContext.textContent = (entry.sourceContexts || []).join(', ');
  els.phrase.textContent = entry.phrase || '';
  els.filename.textContent = targetFilename;
  els.recordingSlug.textContent = recordingSlug;
  els.phraseId.textContent = String(phraseId);
  els.styles.textContent = `Styles: ${(entry.styles || []).join(', ')}`;

  document.querySelectorAll('.nav-line.active').forEach(el => el.classList.remove('active'));
  const active = document.querySelector(`.nav-line[data-index="${index}"]`);
  if (active) active.classList.add('active');
}

function copyText(text, promptLabel) {
  if (!text) return;
  if (navigator.clipboard?.writeText) {
    navigator.clipboard.writeText(text);
  } else {
    window.prompt(promptLabel, text);
  }
}

function copyRecordingFilename() {
  const entry = entries[index];
  copyText(entry?.audioFname || '', 'Copy target filename:');
}

function copyRecordingSlug() {
  const entry = entries[index];
  copyText(entry?.copyValue || entry?.recordingSlug || entry?.hash || '', 'Copy recording slug:');
}

function copyPhraseId() {
  const entry = entries[index];
  copyText(String(entry?.order || index + 1), 'Copy phrase ID:');
}

function nextAndCopySlug() {
  if (!entries.length) return;
  go((index + 1) % entries.length, true, true);
  copyRecordingSlug();
}

document.getElementById('firstButton').addEventListener('click', () => go(0));
document.getElementById('backButton').addEventListener('click', () => go((index - 1 + entries.length) % entries.length));
document.getElementById('nextButton').addEventListener('click', () => go((index + 1) % entries.length, true, true));
document.getElementById('nextCopyButton').addEventListener('click', nextAndCopySlug);
document.getElementById('endButton').addEventListener('click', () => go(entries.length - 1));
document.getElementById('fontSmallerButton').addEventListener('click', () => adjustPhraseSize(-4));
document.getElementById('fontLargerButton').addEventListener('click', () => adjustPhraseSize(4));
els.copyFilenameButton.addEventListener('click', copyRecordingFilename);
els.copySlugButton.addEventListener('click', copyRecordingSlug);
els.copyIdButton.addEventListener('click', copyPhraseId);

document.addEventListener('keydown', event => {
  if (event.key === 'ArrowRight') {
    event.preventDefault();
    go((index + 1) % entries.length, true, true);
  } else if (event.key === 'ArrowLeft') {
    event.preventDefault();
    go((index - 1 + entries.length) % entries.length);
  } else if (event.key === 'Home') {
    event.preventDefault();
    go(0);
  } else if (event.key === 'End') {
    event.preventDefault();
    go(entries.length - 1);
  }
});

els.summary.textContent = `Generated ${data.generatedAt || ''} with ${entries.length} phrases from ${(data.selectedStyles || []).join(', ')}`;
els.textFingerprint.textContent = data.textFingerprint || '';
applyPhraseSize();
renderNav();
go(0, false);
</script>
</body>
</html>
]===]

  return prefix..encoded..suffix
end

function C:exportScriptReaderHtml()
  local entries, selected = self:recordingCoverageEntries()
  if #selected == 0 then
    log('E', logTag, 'No text compositor styles selected')
    return
  end
  if #entries == 0 then
    log('E', logTag, 'No script reader data to export')
    return
  end

  local sm = {
    entries = entries,
    selectedStyles = selected,
  }
  local exportData, exportDataErr = scriptReaderExportData(sm)
  if not exportData then
    log('E', logTag, exportDataErr or 'failed to build script reader export data')
    return
  end

  local html = scriptReaderHtml(exportData, scriptReaderLogoDataUrl())
  if not html then
    log('E', logTag, 'failed to encode script reader HTML data')
    return
  end

  local outDir = '/temp/rally'
  FS:directoryCreate(outDir, true)
  local fname = outDir..'/beamng-voicepack-script_'..exportData.textFingerprint..'.html'
  writeFile(fname, html)

  if FS:fileExists(fname) then
    log('I', logTag, 'Recording script HTML written to: '..fname)
    Engine.Platform.exploreFolder(outDir)
  else
    log('E', logTag, 'failed to write recording script HTML to: '..fname)
  end
end

function C:exportScriptReaderTxt()
  local entries, selected = self:recordingCoverageEntries()
  if #selected == 0 then
    log('E', logTag, 'No text compositor styles selected')
    return
  end
  if #entries == 0 then
    log('E', logTag, 'No script reader data to export')
    return
  end

  local sm = {
    entries = entries,
    selectedStyles = selected,
  }
  local exportData, exportDataErr = scriptReaderExportData(sm)
  if not exportData then
    log('E', logTag, exportDataErr or 'failed to build script reader export data')
    return
  end

  local txt = scriptReaderTxt(exportData)
  local outDir = '/temp/rally'
  FS:directoryCreate(outDir, true)
  local fname = outDir..'/beamng-voicepack-script_'..exportData.textFingerprint..'.txt'
  writeFile(fname, txt)

  if FS:fileExists(fname) then
    log('I', logTag, 'Recording script TXT written to: '..fname)
    Engine.Platform.exploreFolder(outDir)
  else
    log('E', logTag, 'failed to write recording script TXT to: '..fname)
  end
end

function C:storeElevationProfile(elevationProfile)
  self.pacenotesTools.elevationProfile = elevationProfile
  if elevationProfile and #elevationProfile > 0 then
    -- Calculate some basic stats for display
    local minZ = math.huge
    local maxZ = -math.huge
    local totalDistance = 0
    local splitCount = 0
    local racePathnodeCount = 0
    -- local pacenoteWaypointCount = 0

    for i, point in ipairs(elevationProfile) do
      if point.z < minZ then minZ = point.z end
      if point.z > maxZ then maxZ = point.z end
      if point.splitLabel then splitCount = splitCount + 1 end
      if point.isRacePathnode then racePathnodeCount = racePathnodeCount + 1 end
      -- if point.isPacenoteWaypoint then pacenoteWaypointCount = pacenoteWaypointCount + 1 end
      if i > 1 then
        local prevPoint = elevationProfile[i-1]
        local dx = point.x - prevPoint.x
        local dy = point.y - prevPoint.y
        totalDistance = totalDistance + math.sqrt(dx*dx + dy*dy)
      end
    end

    self.pacenotesTools.elevationProfileInfo = {
      pointCount = #elevationProfile,
      minElevation = minZ,
      maxElevation = maxZ,
      elevationChange = maxZ - minZ,
      totalDistance = totalDistance,
      startDistance = elevationProfile[1].distFromStart or 0,
      endDistance = elevationProfile[#elevationProfile].distFromStart or 0,
      splitCount = splitCount,
      racePathnodeCount = racePathnodeCount,
      -- pacenoteWaypointCount = pacenoteWaypointCount
    }

    log('I', logTag, string.format('stored elevation profile: %d points, elevation range %.1f-%.1fm',
      self.pacenotesTools.elevationProfileInfo.pointCount, minZ, maxZ))
  else
    self.pacenotesTools.elevationProfileInfo = nil
    log('W', logTag, 'elevation profile is empty or nil')
  end
end

function C:exportElevationProfileToJson()
  if not self.pacenotesTools.elevationProfile then
    log('W', logTag, 'no elevation profile data to export')
    return
  end

  local timestamp = os.date("%Y%m%d_%H%M%S")
  local filename = string.format('/temp/rally/elevation_profile_%s.json', timestamp)

  local exportData = {
    metadata = self.pacenotesTools.elevationProfileInfo,
    generatedAt = timestamp,
    points = self.pacenotesTools.elevationProfile
  }

  local success = jsonWriteFile(filename, exportData, true)
  if success then
    log('I', logTag, 'exported elevation profile to: ' .. filename)
  else
    log('E', logTag, 'failed to export elevation profile to: ' .. filename)
  end
end

function C:drawElevationProfilePoints()
  if not self.pacenotesTools.showElevationProfilePoints or not self.pacenotesTools.elevationProfile then
    return
  end

  local sphereRadius = 1.0
  local normalColor = ColorF(0.2, 0.8, 0.2, 0.7) -- Green for normal points
  local racePnColor = ColorF(0.8, 0.2, 0.2, 0.9) -- Red for race pathnodes
  -- local pacenoteColor = ColorF(0.2, 0.2, 0.8, 0.9) -- Blue for pacenote waypoints

  for i, point in ipairs(self.pacenotesTools.elevationProfile) do
    local color = normalColor

    -- Use different colors based on point type
    if point.isRacePathnode then
      color = racePnColor
      sphereRadius = 1.5 -- Larger for race pathnodes
    -- elseif point.isPacenoteWaypoint then
      -- color = pacenoteColor
      -- sphereRadius = 1.2 -- Medium for pacenote waypoints
    else
      sphereRadius = 0.8 -- Smaller for regular route points
    end

    local pos = vec3(point.x, point.y, point.z)

    debugDrawer:drawSphere(pos, sphereRadius, color)

    -- Draw text for important points (every 20th point or special points)
    if (i % 20 == 0) or point.isRacePathnode then
      -- or point.isPacenoteWaypoint then
      local textPos = vec3(pos)
      textPos.z = textPos.z + 2.0 -- Offset text above the sphere

      local distKm = (point.distFromStart or 0) / 1000.0
      local text = string.format("%.3fkm | z:%.1fm", distKm, point.z)

      if point.splitLabel then
        text = text .. " [" .. point.splitLabel .. "]"
      end

      -- if point.isRacePathnode then
        -- text = text .. " [RacePathnode]"
      -- elseif point.isPacenoteWaypoint then
        -- text = text .. " [PacenoteWP]"
      -- end

      debugDrawer:drawTextAdvanced(
        textPos,
        String(text),
        ColorF(1, 1, 1, 1), -- White text
        true,
        false,
        ColorI(0, 0, 0, 180), -- Semi-transparent black background
        false,
        false
      )
    end
  end
end

function C:drawGameSettings()
  im.Text('rallyCodriverVoicepackMRU='..tostring(settings.getValue("rallyCodriverVoicepackMRU")))
end

function C:calculateCorners()
  local currentPath = editor_rallyEditor.getCurrentPath()
  if not currentPath then
    log('W', logTag, 'No current path available')
    return
  end

  local snaproad = editor_rallyEditor.getPacenotesWindow():getSnaproad()
  if not snaproad then
    log('W', logTag, 'No snaproad available')
    return
  end

  local points = snaproad:driveline().points
  if not points or #points == 0 then
    log('W', logTag, 'No driveline points available')
    return
  end

  self:storeDrivelinePoints(points)

  -- Build params table from UI values
  local params = {
    lookAheadContext = self.pacenotesTools.params.lookAheadContext[0],
    straightThreshold = self.pacenotesTools.params.straightThreshold[0],
    mergeDistanceThreshold = self.pacenotesTools.params.mergeDistanceThreshold[0],
    maxSimplifyIterations = self.pacenotesTools.params.maxSimplifyIterations[0]
  }

  local detection = PacenoteGenerator.detectCorners(points, params)
  self:storeCornerDetection(detection)
end

function C:storeCornerDetection(detection)
  detection = detection or {}
  self.pacenotesTools.sections = detection.sections or {}
  self.pacenotesTools.corners = detection.corners or {}
  if self.pacenotesTools.corners and #self.pacenotesTools.corners > 0 then
    log('I', logTag, 'Stored '..#self.pacenotesTools.corners..' corners in '..#self.pacenotesTools.sections..' sections')
  else
    log('W', logTag, 'No corners available')
  end
end

function C:storeDrivelinePoints(points)
  self.pacenotesTools.drivelinePoints = {}
  if points then
    for i, point in ipairs(points) do
      -- dump(point.pos)
      table.insert(self.pacenotesTools.drivelinePoints, vec3(point.pos))
    end
  end
  self.pacenotesTools.showDrivelinePoints = true
  log('I', logTag, 'Stored '..#self.pacenotesTools.drivelinePoints..' driveline points')
end

function C:resetCornerDetectionParams()
  local params = self.pacenotesTools.params
  local defaults = PacenoteGenerator.defaultParams
  params.lookAheadContext[0] = defaults.lookAheadContext
  params.straightThreshold[0] = defaults.straightThreshold
  params.mergeDistanceThreshold[0] = defaults.mergeDistanceThreshold
  params.maxSimplifyIterations[0] = defaults.maxSimplifyIterations
end

local clr_darkGrey = ColorF(0.3, 0.3, 0.3, 0.8) -- Dark grey
function C:drawDrivelinePoints()
  if not self.pacenotesTools.showDrivelinePoints then return end
  if not self.pacenotesTools.drivelinePoints or #self.pacenotesTools.drivelinePoints < 2 then
    return
  end

  local sections = self.pacenotesTools.sections
  if sections and #sections > 0 then
    -- Draw generated sections: red for right, blue for left, grey for straight.
    local clr_left = ColorF(0, 0.5, 1, 0.8)  -- Blue for left turns
    local clr_right = ColorF(1, 0, 0, 0.8)   -- Red for right turns

    for _, section in ipairs(sections) do
      -- Choose color based on direction
      local color
      if section.direction == " left" then
        color = clr_left
      elseif section.direction == " right" then
        color = clr_right
      else
        color = clr_darkGrey
      end

      -- Draw lines between nodes in this section.
      if section.nodes and #section.nodes > 1 then
        for j = 1, #section.nodes - 1 do
          local p1 = vec3(section.nodes[j].pos)
          local p2 = vec3(section.nodes[j + 1].pos)
          debugDrawer:drawLineInstance(p1, p2, 10, color)
        end
      end

      -- Draw sphere at corner start for visibility
      if section.direction ~= "" then
        debugDrawer:drawSphere(vec3(section.pos), 1.0, color)
      end
    end
  elseif self.pacenotesTools.drivelinePoints and #self.pacenotesTools.drivelinePoints > 0 then
    -- Fallback: draw raw driveline points if no corners detected
    for i = 1, #self.pacenotesTools.drivelinePoints - 1 do
      debugDrawer:drawLineInstance(self.pacenotesTools.drivelinePoints[i], self.pacenotesTools.drivelinePoints[i+1], 10, clr_darkGrey)
    end
  end
end

function C:clearDrivelinePoints()
  self.pacenotesTools.drivelinePoints = nil
  self.pacenotesTools.showDrivelinePoints = false
  self.pacenotesTools.sections = nil
  self.pacenotesTools.corners = nil
end

local clr_trafficZone = ColorF(0.1, 0.75, 1, 0.35)
local clr_trafficZoneCenter = ColorF(0, 0.95, 1, 1)

function C:drawTrafficZones()
  if not self.trafficTools.showZones or not self.trafficTools.zones then return end

  for _, zone in ipairs(self.trafficTools.zones) do
    if zone.pos and zone.radius then
      debugDrawer:drawSphere(zone.pos, zone.radius, clr_trafficZone)
      debugDrawer:drawSphere(zone.pos, 0.5, clr_trafficZoneCenter)
    end
  end
end

function C:refreshRallyLoopMissions()
  self.trafficTools.rallyLoopMissions = {"<none>"}
  self.trafficTools.selectedRallyLoopIndex[0] = 0
  self.trafficTools.selectedRallyLoopId = nil

  local missions = gameplay_missions_missions.getMissionsByFilter({
    missionType = "rallyLoop",
    level = getCurrentLevelIdentifier()
  })

  for _, mission in ipairs(missions) do
    local translatedName = _tr(mission.name)
    local displayName = string.format("%s (%s)", translatedName, mission.id)
    table.insert(self.trafficTools.rallyLoopMissions, displayName)
  end
end

function C:getSelectedRallyLoopId()
  local luaIndex = self.trafficTools.selectedRallyLoopIndex[0] + 1
  if luaIndex > 1 and luaIndex <= #self.trafficTools.rallyLoopMissions then
    local selected = self.trafficTools.rallyLoopMissions[luaIndex]
    local missionId = selected:match("%((.+)%)$")
    return missionId
  end
  return nil
end

function C:onUpdate()
  -- Only draw debug visualizations when the Pacenotes Tools section is expanded
  if self.pacenotesTools.sectionExpanded then
    self:drawElevationProfilePoints()
    self:drawDrivelinePoints()
  end

  -- Draw traffic zones when enabled
  self:drawTrafficZones()
end

function C:draw()
  if im.CollapsingHeader1("Voicepack Tools", im.TreeNodeFlags_DefaultClosed) then
    im.Text("Voicepack Skeleton")
    im.SameLine()
    im.SetNextItemWidth(160)
    if im.BeginCombo("##VoicepackSkeletonCompositor", self.selectedSkeletonCompositor or "None") then
      for _, compositorName in ipairs(self.compositors or {}) do
        if im.Selectable1(compositorName, compositorName == self.selectedSkeletonCompositor) then
          self.selectedSkeletonCompositor = compositorName
        end
      end
      im.EndCombo()
    end
    im.SameLine()
    if im.Button("Generate Voicepack Skeleton") then
      self:generateVoicepackSkeleton()
    end
    im.Text("Output dir: " .. self:voicepackSkeletonOutDir())
    im.Separator()

    im.Text("Recording Coverage Styles")
    im.SameLine()
    if im.SmallButton("All##voicepackStylesAll") then
      for _, compositorName in ipairs(self.compositors or {}) do
        self.compositorChecked[compositorName] = true
      end
    end
    im.SameLine()
    if im.SmallButton("None##voicepackStylesNone") then
      for _, compositorName in ipairs(self.compositors or {}) do
        self.compositorChecked[compositorName] = false
      end
    end
    im.SameLine()
    if im.Button("Export Recording HTML") then
      self:exportScriptReaderHtml()
    end
    im.SameLine()
    if im.Button("Export TXT") then
      self:exportScriptReaderTxt()
    end

    for _, group in ipairs(self.compositorGroups or {}) do
      if im.TreeNodeEx1(group.label, im.TreeNodeFlags_DefaultOpen) then
        for _, compositorName in ipairs(group.items) do
          local checked = im.BoolPtr(self.compositorChecked[compositorName] == true)
          if im.Checkbox(styleLeaf(compositorName).."##voicepackStyle_"..compositorName, checked) then
            self.compositorChecked[compositorName] = checked[0]
          end
        end
        im.TreePop()
      end
    end

    local selectedCount = #(self:selectedCompositors())
    im.Text(string.format("%d of %d styles selected", selectedCount, #(self.compositors or {})))
  end

  im.Separator()

  local sectionExpanded = im.CollapsingHeader1("Pacenotes Tools", im.TreeNodeFlags_DefaultClosed)
  self.pacenotesTools.sectionExpanded = sectionExpanded
  if sectionExpanded then
    im.TextColored(im.ImVec4(1, 0.7, 0.3, 1), "Note: Pacenotes debug drawing is hidden while this section is expanded")
    im.Separator()
    im.Text("Corner Detection")

    if im.Button("Detect Corners from Driveline") then
      self:calculateCorners()
    end
    im.tooltip("Load driveline and detect corners for visualization.\nDoes not create pacenotes.")

    im.SameLine()

    if im.Button("Generate Pacenotes") then
      if editor_rallyEditor and editor_rallyEditor.getCurrentPath() then
        local currentPath = editor_rallyEditor.getCurrentPath()
        if currentPath and currentPath.generatePacenotes then
          im.OpenPopup("Generate Pacenotes##devToolsGenPacenotes")
        else
          log('W', logTag, 'Notebook not available or method not found')
        end
      else
        log('W', logTag, 'Rally editor not active or no notebook loaded')
      end
    end
    im.tooltip("Generate pacenotes from detected corners.\nThis will clear all existing pacenotes!")

    -- Generate Pacenotes confirmation dialog
    if im.BeginPopupModal("Generate Pacenotes##devToolsGenPacenotes", nil, im.WindowFlags_AlwaysAutoResize) then
      im.Text("Generate pacenotes from detected corners? (experimental)")
      im.Text("This will clear all pacenotes.")
      im.Text("Make a backup before proceeding.")
      im.Separator()
      if im.Button("Ok", im.ImVec2(120,0)) then
        local currentPath = editor_rallyEditor.getCurrentPath()
        if currentPath then
          -- Pass only filtered left/right corner candidates to generatePacenotes.
          currentPath:generatePacenotes(self.pacenotesTools.corners)
          -- Refresh to ensure snaproad is loaded and text compositor cache is cleared
          editor_rallyEditor.getPacenotesWindow():refreshPacenotesTab()
        end
        im.CloseCurrentPopup()
      end
      im.SameLine()
      if im.Button("Cancel", im.ImVec2(120,0)) then
        im.CloseCurrentPopup()
      end
      im.EndPopup()
    end

    -- Corner detection parameters
    im.Text("Corner Detection Parameters:")

    im.PushItemWidth(150)

    if im.SliderInt("Look Ahead Context", self.pacenotesTools.params.lookAheadContext, 1, 10) then
      -- Parameter changed
    end
    im.tooltip("How many nodes ahead/behind to analyze (1-10)\nLower = more sensitive to local changes")

    if im.SliderFloat("Straight Filter (deg)", self.pacenotesTools.params.straightThreshold, 1.0, 10.0, "%.1f") then
      -- Parameter changed
    end
    im.tooltip("Generator-only filter: spans below this angle are shown as grey straights and excluded from pacenote generation.")

    if im.SliderFloat("Straight Merge Distance (m)", self.pacenotesTools.params.mergeDistanceThreshold, 0.05, 1.0, "%.2f") then
      -- Parameter changed
    end
    im.tooltip("Generator-only filter: conservative distance threshold for absorbing near-inline nodes into straight spans.")

    if im.SliderInt("Simplify Iterations", self.pacenotesTools.params.maxSimplifyIterations, 1, 10) then
      -- Parameter changed
    end
    im.tooltip("Max iterations for simplification (1-10)")

    im.PopItemWidth()

    if im.Button("Reset Detection Params") then
      self:resetCornerDetectionParams()
    end
    im.tooltip("Reset corner detection controls to conservative defaults.\nDoes not change the real driveline.")

    im.Separator()

    -- Display driveline points info and controls
    if self.pacenotesTools.drivelinePoints then
      im.Text(string.format("Driveline Points: %d", #self.pacenotesTools.drivelinePoints))

      if self.pacenotesTools.corners then
        im.Text(string.format("Detected Corners: %d", #self.pacenotesTools.corners))
      end
      if self.pacenotesTools.sections then
        local straightSections = 0
        for _, section in ipairs(self.pacenotesTools.sections) do
          if section.direction == "" then straightSections = straightSections + 1 end
        end
        im.Text(string.format("Straight Sections: %d", straightSections))
      end

      local showPointsPtr = im.BoolPtr(self.pacenotesTools.showDrivelinePoints)
      if im.Checkbox("Show Driveline in 3D", showPointsPtr) then
        self.pacenotesTools.showDrivelinePoints = showPointsPtr[0]
      end
      im.tooltip("Display detected sections in 3D world\nRed = right turns, blue = left turns, grey = filtered straights")

      if im.Button("Clear Driveline Points") then
        self:clearDrivelinePoints()
      end
      im.tooltip("Clear the devtool driveline/corner visualization.\nDoes not delete notebook pacenotes.")
    else
      im.Text("No driveline points loaded")
    end

    im.Separator()
    im.Text("Elevation Profile")

    if im.Button("Generate Elevation Profile") then
      if editor_rallyEditor and editor_rallyEditor.getCurrentPath() then
        local pacenotesWindow = editor_rallyEditor.getPacenotesWindow()
        if pacenotesWindow and pacenotesWindow.generateElevationProfile then
          local elevationProfile = pacenotesWindow:generateElevationProfile()
          self:storeElevationProfile(elevationProfile)
        else
          log('W', logTag, 'Pacenotes window not available or method not found')
        end
      else
        log('W', logTag, 'Rally editor not active or no notebook loaded')
      end
    end
    im.tooltip("Generates elevation profile using metadata distances and split labels from route points")



    -- Display elevation profile information
    if self.pacenotesTools.elevationProfileInfo then
      im.Separator()
      im.Text("Elevation Profile Data:")
      im.Text(string.format("Points: %d", self.pacenotesTools.elevationProfileInfo.pointCount))
      im.Text(string.format("Min Elevation: %.1fm", self.pacenotesTools.elevationProfileInfo.minElevation))
      im.Text(string.format("Max Elevation: %.1fm", self.pacenotesTools.elevationProfileInfo.maxElevation))
      im.Text(string.format("Elevation Change: %.1fm", self.pacenotesTools.elevationProfileInfo.elevationChange))
      im.Text(string.format("Total Distance: %.1fm", self.pacenotesTools.elevationProfileInfo.totalDistance))
      im.Text(string.format("Route Distance: %.1f - %.1fm",
        self.pacenotesTools.elevationProfileInfo.startDistance, self.pacenotesTools.elevationProfileInfo.endDistance))
      im.Text(string.format("Split Points: %d", self.pacenotesTools.elevationProfileInfo.splitCount))
      im.Text(string.format("Race Pathnodes: %d", self.pacenotesTools.elevationProfileInfo.racePathnodeCount))

      if im.Button("Export to JSON") then
        self:exportElevationProfileToJson()
      end

      if im.Button("Clear Data") then
        self.pacenotesTools.elevationProfile = nil
        self.pacenotesTools.elevationProfileInfo = nil
        self.pacenotesTools.showElevationProfilePoints = false
      end

      -- Visual debugging toggle
      local showPointsPtr = im.BoolPtr(self.pacenotesTools.showElevationProfilePoints)
      if im.Checkbox("Show Points in 3D", showPointsPtr) then
        self.pacenotesTools.showElevationProfilePoints = showPointsPtr[0]
      end
      im.tooltip("Display elevation profile points as colored spheres in the 3D world\nGreen: Regular points\nRed: Race pathnodes")
    else
      im.Text("No elevation profile data available")
    end
  end

  im.Separator()

  if im.CollapsingHeader1("Traffic", im.TreeNodeFlags_DefaultClosed) then
    im.TextColored(im.ImVec4(1, 0.7, 0.3, 1), "To see applied traffic exclusion: View > Visualization Settings... > Debug Tab > Navgraph: Road Type")
    im.Separator()

    im.Text("Zone Parameters:")
    im.PushItemWidth(150)

    im.SliderFloat("Zone Radius (m)", self.trafficTools.zoneRadius, 1.0, 50.0, "%.1f")
    im.tooltip("Radius of each exclusion zone sphere")

    im.PopItemWidth()
    im.Separator()

    local missionId = nil
    if editor_rallyEditor then
      missionId = editor_rallyEditor.getMissionId()
    end

    im.Text("Current Rally Stage: auto-generated driveline zones")
    im.TextDisabled("Uses Zone Radius (m); sample spacing is 1.5x radius.")
    if missionId then
      im.Text("Current Mission: " .. tostring(missionId))

      if im.Button("Update Navgraph") then
        local mission = gameplay_missions_missions.getMissionById(missionId)
        local radius = self.trafficTools.zoneRadius[0]
        local sampleDistance = 1.5 * radius
        local zones = TrafficExclusion.createZones({mission}, radius, sampleDistance)
        self.trafficTools.zones = zones
        map.setTrafficExclusionZones(zones)
        map.reset() -- Reloads the navgraph applying the zones
        log('I', logTag, string.format("Created %d traffic exclusion zones (radius=%.1f, sample=%.1f)", #zones, radius, sampleDistance))
      end
      im.tooltip("Create auto-generated traffic exclusion zones from the current rally stage driveline and reload navgraph.")

      im.SameLine()

      if im.Button("Clear Traffic Zones") then
        self.trafficTools.zones = nil
        map.clearTrafficExclusionZones()
        map.reset() -- Reloads the navgraph clearing the zones
      end
      im.tooltip("Clear all traffic exclusion zones and reload navgraph.")

      -- Zone visualization toggle
      if self.trafficTools.zones and #self.trafficTools.zones > 0 then
        im.Text(string.format("Active Zones: %d", #self.trafficTools.zones))

        local showZonesPtr = im.BoolPtr(self.trafficTools.showZones)
        if im.Checkbox("Show Zones in 3D", showZonesPtr) then
          self.trafficTools.showZones = showZonesPtr[0]
        end
        im.tooltip("Display traffic exclusion zone spheres in 3D world")
      end
    else
      im.Text("Current Mission: <none>")
    end

    im.Separator()
    im.Text("Rally Loop Traffic Exclusion")
    im.TextDisabled("Loads the loop's trafficGatedRoads.grzones.json and generated rally stage zones.")

    -- Refresh button and dropdown
    if im.Button("Refresh##rallyLoopRefresh") then
      self:refreshRallyLoopMissions()
    end
    im.tooltip("Refresh the list of rallyLoop missions on this level")

    im.SameLine()

    im.PushItemWidth(250)
    local currentSelection = self.trafficTools.rallyLoopMissions[self.trafficTools.selectedRallyLoopIndex[0] + 1] or "<none>"
    if im.BeginCombo("##rallyLoopMission", currentSelection, im.ComboFlags_HeightLarge) then
      for i, missionName in ipairs(self.trafficTools.rallyLoopMissions) do
        if im.Selectable1(missionName, i == self.trafficTools.selectedRallyLoopIndex[0] + 1) then
          self.trafficTools.selectedRallyLoopIndex[0] = i - 1
          self.trafficTools.selectedRallyLoopId = self:getSelectedRallyLoopId()
        end
      end
      im.EndCombo()
    end
    im.PopItemWidth()

    im.SameLine()

    local hasSelection = self.trafficTools.selectedRallyLoopId ~= nil
    if not hasSelection then
      im.BeginDisabled()
    end
    if im.Button("Load##rallyLoopLoad") then
      local mission = gameplay_missions_missions.getMissionById(self.trafficTools.selectedRallyLoopId)
      if mission then
        local radius = self.trafficTools.zoneRadius[0]
        local zones = TrafficExclusion.applyForRallyLoop(mission, radius)
        self.trafficTools.zones = zones
        log('I', logTag, string.format("Loaded traffic exclusion for rallyLoop: %s (%d zones)", self.trafficTools.selectedRallyLoopId, #zones))
      else
        log('W', logTag, "Could not find mission: " .. tostring(self.trafficTools.selectedRallyLoopId))
      end
    end
    im.tooltip("Apply traffic exclusion zones for this rallyLoop: grzones file plus generated stage driveline zones.")
    if not hasSelection then
      im.EndDisabled()
    end

    im.SameLine()

    if im.Button("Unload##rallyLoopUnload") then
      TrafficExclusion.clearTrafficExclusion()
      self.trafficTools.zones = nil
      log('I', logTag, "Cleared traffic exclusion zones")
    end
    im.tooltip("Clear all traffic exclusion zones")
  end

  im.Separator()

  if im.CollapsingHeader1("Game Settings", im.TreeNodeFlags_DefaultClosed) then
    self:drawGameSettings()
  end

  -- if im.Button("Load Route") then
  --   self:loadRoute()
  -- end
  -- if self.drivelineRoute then
  --   im.Text(string.format("Next Pacenote Idx: %d", self.drivelineRoute.nextPacenoteIdx))

  --   local nextPacenote = self.drivelineRoute.pacenotes[self.drivelineRoute.nextPacenoteIdx]
  --   if nextPacenote then
  --     im.Text(string.format("Next Pacenote: %s(%d) length=%0.1f", nextPacenote.name, nextPacenote.id, nextPacenote:getCachedLength() or 0.0))
  --   else
  --     im.Text("Next Pacenote: none")
  --   end

  --   if im.BeginTable("eventLog", 1, im.TableFlags_Borders) then
  --     im.TableSetupColumn("Event")
  --     im.TableHeadersRow()

  --     for i = #self.drivelineRoute.eventLog, 1, -1 do
  --       local event = self.drivelineRoute.eventLog[i]
  --       im.TableNextRow()
  --       im.TableNextColumn()
  --       im.Text(event:gsub("%%", "%%%%"))
  --     end

  --     im.EndTable()
  --   end

  --   self.drivelineRoute:onUpdate()
  --   self.drivelineRoute:drawDebugDrivelineRoute()
  -- end

end

function C:onVehicleResetted()
  -- self:loadRoute()
  -- self.drivelineRoute:onVehicleResetted()
end

function C:isPacenotesToolsSectionExpanded()
  return self.pacenotesTools.sectionExpanded or false
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
