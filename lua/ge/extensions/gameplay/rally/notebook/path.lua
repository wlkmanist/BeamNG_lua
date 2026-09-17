-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local logTag = ''
local C = {}
local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local voicepack = require('/lua/ge/extensions/gameplay/rally/voicepack')
local RallyEnums = require('/lua/ge/extensions/gameplay/rally/enums')
local VisualCompositor = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/visualCompositor')
local TextCompositor = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/textCompositor')
local compositorUtil = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/compositorUtil')
local systemPacenoteNames = require('/lua/ge/extensions/gameplay/rally/notebook/systemPacenotes')

local currentVersion = "4"
local sharedCustomSystemDir = 'lua/ge/extensions/gameplay/rally/audio/custom/ak/system'

function C:getNextUniqueIdentifier()
  self._uid = self._uid + 1
  return self._uid
end

function C:init(name)
  self._uid = 0

  self.name = name or "Primary"
  self.description = ""
  self.authors = ""
  self.metadata = {}
  self.version = currentVersion
  self.created_at = os.time()
  self.updated_at = self.created_at

  self.pacenotes = require('/lua/ge/extensions/gameplay/util/sortedList')(
    "pacenotes",
    self,
    require('/lua/ge/extensions/gameplay/rally/notebook/pacenote')
  )

  self.id = self:getNextUniqueIdentifier()
  self.fname = nil
  self.validation_issues = {}

  self.audioMode = RallyEnums.pacenoteAudioMode.structuredOffline

  self.textCompositor = nil
  self.visualCompositor = nil
  self._activeVoicepackKey = nil
  self._activeVoicepackResult = nil
  self._customSystemPacenoteCache = nil
  self._customAudioMapping = nil

  self.snaproad = nil
end

-- Snaproad is supplied lazily by whichever consumer owns the road geometry
-- (the editor's pacenotes window or the runtime RallyManager). distance
-- calculations that walk the road require it, so autofill is triggered as
-- soon as one is attached.
function C:setSnaproad(sn)
  self.snaproad = sn
  if sn then
    self:autofillDistanceCalls()
  end
end

function C:getSnaproad()
  return self.snaproad
end

-- function C:getSnaproadType()
--   local drivelineMode = self:missionSettings():getDrivelineMode()
--   if not drivelineMode then
--     return nil
--   end
--   return RallyEnums.drivelineModeNames[drivelineMode]
-- end

-- Returns the toolbox-driven voicepack pick if a rally manager is currently running.
-- This is the bridge between the in-game picker and the editor (which falls back to settings).
function C:_getRallyManagerPick()
  -- Editor's pick wins for the notebook instance the editor currently owns; this lets the rally
  -- editor's voicepack dropdown drive style/audioMode resolution without going through settings.
  if editor_rallyEditor and editor_rallyEditor.getCurrentVoicepackPick and editor_rallyEditor.getCurrentPath then
    if editor_rallyEditor.getCurrentPath() == self then
      local pick = editor_rallyEditor.getCurrentVoicepackPick()
      if pick then return pick, true end
    end
  end

  if gameplay_rally and gameplay_rally.getRallyManager then
    local rm = gameplay_rally.getRallyManager()
    if rm and rm.getVoicepackPick then
      local writesSettings = rm.getVoicepackPickWritesSettings and rm:getVoicepackPickWritesSettings() or true
      return rm:getVoicepackPick(), writesSettings
    end
  end
  return nil, true
end

-- Returns the resolved voicepack dirname and its info entry, based on the toolbox pick (when a
-- rally session is active) or accepted-language/MRU preferences. The pick may be global or
-- mission-scope; both are handled by voicepack.resolveEffectiveEntry.
local function pickCacheKey(pick)
  if not pick or pick.type == 'auto' or pick.type == 'preferences' then return 'preferences' end
  return table.concat({
    tostring(pick.type or ''),
    tostring(pick.id or ''),
    tostring(pick.scope or ''),
    tostring(pick.missionId or ''),
    tostring(pick.dirname or ''),
  }, '|')
end

function C:invalidateActiveVoicepackCache()
  self._activeVoicepackKey = nil
  self._activeVoicepackResult = nil
  self.pacenoteMetadataOfflineStructured = nil
  self._pacenoteMetadataOfflineStructuredKey = nil
end

function C:resolveActiveVoicepack()
  local missionDir = self:getMissionDir()
  local missionId = self:getMissionId()
  local pick, writeSettings = self:_getRallyManagerPick()
  local cacheKey = tostring(missionDir or '')..'|'..tostring(missionId or '')..'|'..pickCacheKey(pick)
  if self._activeVoicepackKey ~= cacheKey then
    self._activeVoicepackResult = { voicepack.resolveEffectiveEntry(missionDir, pick, { missionId = missionId, writeSettings = writeSettings }) }
    self._activeVoicepackKey = cacheKey
  end
  return self._activeVoicepackResult[1], self._activeVoicepackResult[2], self._activeVoicepackResult[3]
end

function C:getActiveCompositorName()
  local _, entry = self:resolveActiveVoicepack()
  if entry and entry.compositorStyle then
    -- Custom/pro audio packs are pre-recorded and declare no compositorStyle, so there is
    -- no matching compositor module to load; guard anyway in case one is set without a module.
    if self:isAudioModeCustom()
       and not FS:fileExists('/lua/ge/extensions/gameplay/rally/compositors/styles/'..entry.compositorStyle..'.lua') then
      return nil
    end
    return entry.compositorStyle
  end
  return nil
end

function C:getTextCompositor()
  local compositorName = self:getActiveCompositorName()
  local _, voicepackEntry = self:resolveActiveVoicepack()
  if not compositorName then
    -- custom audio mode is expected to have no voicepack/compositor; skip silently.
    if not self:isAudioModeCustom() then
      log('E', logTag, 'getTextCompositor: no voicepack matches current settings')
    end
    self.textCompositor = nil
    return nil
  end

  if not self.textCompositor or compositorName ~= self.textCompositor.compositorName then
    self.textCompositor = TextCompositor(compositorName, self:getMissionDir())
    if not self.textCompositor:load() then
      log('E', logTag, 'getTextCompositor: failed to load text compositor')
      self.textCompositor = nil
    end
  end
  if self.textCompositor then
    self.textCompositor:setVoicepackEntry(voicepackEntry)
  end
  return self.textCompositor
end

function C:getOfflineTextCompositor()
  local compositorName = self:getActiveCompositorName()
  local _, voicepackEntry = self:resolveActiveVoicepack()
  if not compositorName then
    if not self:isAudioModeCustom() then
      log('E', logTag, 'getOfflineTextCompositor: no voicepack matches current settings')
    end
    self._offlineTextCompositor = nil
    return nil
  end

  if not self._offlineTextCompositor or compositorName ~= self._offlineTextCompositor.compositorName then
    self._offlineTextCompositor = TextCompositor(compositorName, self:getMissionDir())
    if not self._offlineTextCompositor:load() then
      log('E', logTag, 'getOfflineTextCompositor: failed to load text compositor for '..compositorName)
      self._offlineTextCompositor = nil
    end
  end

  if self._offlineTextCompositor then
    self._offlineTextCompositor:setVoicepackEntry(voicepackEntry)
  end

  return self._offlineTextCompositor
end

function C:getVisualCompositor2()
  if not self.visualCompositor then
    if not self:getTextCompositor() then
      if not self:isAudioModeCustom() then
        log('E', logTag, 'getVisualCompositor2: no text compositor')
      end
      self.visualCompositor = nil
    else
      self.visualCompositor = VisualCompositor(self:getTextCompositor())
    end
  end
  return self.visualCompositor
end

function C:appendPacenotes(pacenotes)
  for _,pn in ipairs(pacenotes) do
    local newPn = self.pacenotes:create()
    newPn:onDeserialized(pn, {})
  end
end

function C:deleteAllPacenotes()
  self.pacenotes = require('/lua/ge/extensions/gameplay/util/sortedList')(
    "pacenotes",
    self,
    require('/lua/ge/extensions/gameplay/rally/notebook/pacenote')
  )
end

function C:hasAnyPacenotes()
  return #self.pacenotes.sorted > 0
end

-- a path looks like:
-- /gameplay/missions/gridmap_v2/rallyStage/rally-test-1/aipacenotes/notebooks/primary.notebook.json
-- we want to return this string: gridmap_v2/rallyStage/rally-test-1
function C:getMissionId()
  local missionDir = self:getMissionDir()
  if not missionDir then return nil end
  -- Match everything after /missions/
  local pattern = "/missions/(.+)$"
  local segment = missionDir:match(pattern)
  return segment
end

function C:getMissionDir()
  if not self.fname then return nil end

  -- looks like: C:\...gameplay\missions\pikespeak\rallyStage\aip-pikes-peak-2\rally\notebooks\
  local notebooksDir = self:dir()
  -- log('D', 'wtf', 'notebooksDir: '..notebooksDir)
  local rallyDir = rallyUtil.stripBasename(notebooksDir)
  -- log('D', 'wtf', 'rallyDir: '..rallyDir)
  -- now looks like: C:\...gameplay\missions\pikespeak\rallyStage\aip-pikes-peak-2\rally
  local missionDir = rallyUtil.stripBasename(rallyDir)
  -- log('D', 'wtf', 'missionDir: '..missionDir)
  -- now looks like: C:\...gameplay\missions\pikespeak\rallyStage\aip-pikes-peak-2

  return missionDir
end

function C:getMissionType()
  local missionDir = self:getMissionDir()
  if not missionDir then return nil end

  local infoPath = missionDir .. "/info.json"
  local info = jsonReadFile(infoPath)
  if info and info.missionType then
    return info.missionType
  end

  return nil
end

function C:dir()
  if not self.fname then return nil end
  local dir, filename, ext = path.split(self.fname)
  return dir
end

function C:basename()
  if not self.fname then return nil end
  local dir, filename, ext = path.split(self.fname)
  return filename
end

function C:basenameNoExt()
  if not self.fname then return nil end
  local _, filename, _ = path.splitWithoutExt(self.fname)
  _, filename, _ = path.splitWithoutExt(filename)
  return filename
end

function C:setFname(newFname)
  self.fname = newFname
  self:invalidateActiveVoicepackCache()
end

function C:save(fname)
  fname = fname or self.fname
  if not fname then
    log('W', logTag, 'couldnt save notebook because no filename was set')
    return false
  end

  self.updated_at = os.time()

  local json = self:onSerialize()
  local saveOk = jsonWriteFile(fname, json, true)
  if not saveOk then
    log('E', logTag, 'error saving notebook')
  end
  log('I', logTag, 'saved notebook: '..fname)

  return saveOk
end

function C:reload()
  if not self.fname then return end

  local json = jsonReadFile(self.fname)
  if not json then
    log('E', logTag, 'couldnt find notebook file')
  end

  self:onDeserialized(json)
end

function C:validate()
  self.validation_issues = {}
end

function C:is_valid()
  return #self.validation_issues == 0
end

local function extractTrailingNumber(str)
  local num = string.match(str, "%d+%.?%d*$")
  return num and tonumber(num) or nil
end

local function sortByNameNumeric(a, b)
  local numA = extractTrailingNumber(a.name)
  local numB = extractTrailingNumber(b.name)

  if numA and numB then
    -- If both have numbers, compare by number
    return numA < numB
  elseif numA then
    -- If only a has a number, it comes first
    return true
  elseif numB then
    -- If only b has a number, it comes first
    return false
  else
    -- If neither has a number, compare by name
    return a.name < b.name
  end
end

function C:sortPacenotesByName()
  local newList = {}
  for i, v in ipairs(self.pacenotes.sorted) do
    table.insert(newList, v)
  end

  table.sort(newList, sortByNameNumeric)

  -- Assign "sortOrder" in the sorted list
  for i, v in ipairs(newList) do
    v.sortOrder = i
  end

  -- sortOrder shifted; custom-audio interpolation depends on pacenote order.
  self:invalidateCustomAudioMapping()

  self.pacenotes:sort()
end

function C:nextImportIdent()
  local importIdentifiers = {}

  for _, pacenote in ipairs(self.pacenotes.sorted) do
    -- Extract the alphanumeric identifier from pacenote names that match "Import_X"
    local identifier = string.match(pacenote.name, "^Import_([%w]+)")
    if identifier then
      table.insert(importIdentifiers, identifier)
    end
  end

  -- Sort the identifiers and return the last one
  if #importIdentifiers > 0 then
    table.sort(importIdentifiers)
    local letter = importIdentifiers[#importIdentifiers]
    local asciiValue = string.byte(letter)
    local nextAsciiValue = asciiValue + 1
    local nextLetter = string.char(nextAsciiValue)
    -- if you hit Z, it will return non alphabetic chars.
    return nextLetter
  end

  return 'A' -- have to start somewhere
end

function C:cleanupPacenoteNames()
  for i, v in ipairs(self.pacenotes.sorted) do
    -- Pattern to match a name ending with a number: capture the non-numeric part and the numeric part
    local baseName, number = string.match(v.name, "(.-)%s*([%d%.]+)$")

    if baseName and number then
      -- If the name has a number at the end, replace it with the new index
      v.name = baseName .. " " .. i
    else
      -- If the name does not have a number at the end, append the index
      v.name = v.name .. " " .. i
    end
  end

  -- re-index names.
  self.pacenotes:buildNamesDir()
end

local function drawPacenotesAsRainbow(pacenotes, selection_state, globalOpacity)
  for _,pacenote in ipairs(pacenotes) do
    pacenote:drawDebugPacenoteNoSelection(selection_state, globalOpacity)
  end
end

local function showAdjacentPacenoteText()
  return not editor_rallyEditor or not editor_rallyEditor.getPrefShowAdjacentPacenoteText or editor_rallyEditor.getPrefShowAdjacentPacenoteText()
end

local function drawPacenotesAsBackground(pacenotes, skip_pn, selection_state, globalOpacity, showText)
  local skip_i = nil
  for i,pacenote in ipairs(pacenotes) do
    if pacenote.id == skip_pn.id then
      skip_i = i
      break
    end
  end

  if skip_i then
    local show_after_count = 1
    local start_i = skip_i+1
    local end_i = start_i+show_after_count-1
    for i = start_i,end_i do
      local pacenote = pacenotes[i]
      if pacenote then
        pacenote:drawDebugPacenoteBackground(selection_state, globalOpacity, showText)
      end
    end

    local show_before_count = 1
    start_i = skip_i-show_before_count
    end_i = skip_i-1
    for i = start_i,end_i do
      local pacenote = pacenotes[i]
      if pacenote then
        pacenote:drawDebugPacenoteBackground(selection_state, globalOpacity, showText)
      end
    end
  end
end

function C:getAdjacentPacenoteSet(selected_pn_id)
  local pacenotes = self.pacenotes.sorted

  local function getOrNullify(i)
    local pn = pacenotes[i]
    if pn and not pn.missing then
      return pn
    else
      return nil
    end
  end

  for i,pacenote in ipairs(pacenotes) do
    if pacenote.id == selected_pn_id then
      return getOrNullify(i-1), pacenote, getOrNullify(i+1)
    end
  end

  return nil, nil, nil
end

function C:drawDebugNotebook(pacenoteToolsState, globalOpacity)
  pacenoteToolsState = pacenoteToolsState or { hover_wp_id = nil, selected_wp_id = nil }
  local pacenotes = self.pacenotes.sorted
  local pn_prev, pn_sel, pn_next = self:getAdjacentPacenoteSet(pacenoteToolsState.selected_pn_id)

  if pn_sel and pacenoteToolsState.selected_wp_id then
    pn_sel:drawDebugPacenoteSelected(pacenoteToolsState, globalOpacity)

    if editor_rallyEditor.getPrefShowPreviousPacenote() and pn_prev and pn_prev.id ~= pn_sel.id then
      pn_prev:drawDebugPacenotePrev(pacenoteToolsState, pn_sel, globalOpacity)
    end

    if editor_rallyEditor.getPrefShowNextPacenote() and pn_next and pn_next.id ~= pn_sel.id then
      pn_next:drawDebugPacenoteNext(pacenoteToolsState, pn_sel, globalOpacity)
    end
  elseif pn_sel then
    pn_sel:drawDebugPacenoteSelected(pacenoteToolsState, globalOpacity)
    drawPacenotesAsBackground(pacenotes, pn_sel, pacenoteToolsState, globalOpacity, showAdjacentPacenoteText())
  else
    drawPacenotesAsRainbow(pacenotes, pacenoteToolsState, globalOpacity)
  end
end

local function pacenoteOverlapsDrawWindow(pacenote, window)
  if not window then return true end
  local wpCs = pacenote:getCornerStartWaypoint()
  local wpCe = pacenote:getCornerEndWaypoint()
  local csLoc = wpCs and wpCs._driveline_location or nil
  local ceLoc = wpCe and wpCe._driveline_location or nil
  local startDistance = math.huge
  local endDistance = -math.huge

  if csLoc and csLoc.distanceAlongRoute then
    startDistance = math.min(startDistance, csLoc.distanceAlongRoute)
    endDistance = math.max(endDistance, csLoc.distanceAlongRoute)
  end
  if ceLoc and ceLoc.distanceAlongRoute then
    startDistance = math.min(startDistance, ceLoc.distanceAlongRoute)
    endDistance = math.max(endDistance, ceLoc.distanceAlongRoute)
  end

  if startDistance == math.huge then return true end
  return endDistance >= window.startDistance and startDistance <= window.endDistance
end

function C:drawDebugNotebookForPartitionAllSnaproad(pacenoteToolsState, globalOpacity, window)
  local pacenotes = self.pacenotes.sorted

  local selectionState = {
    hover_wp_id = nil,
    selected_wp_id = nil,
  }
  for _,pacenote in ipairs(pacenotes) do
    if pacenoteOverlapsDrawWindow(pacenote, window) then
      pacenote:drawDebugPacenotePartitionAllSnaproad(pacenoteToolsState, selectionState)
    end
  end
end

function C:onSerialize()
  return {
    name = self.name,
    description = self.description,
    authors = self.authors,
    metadata = self.metadata,
    updated_at = self.updated_at,
    created_at = self.created_at,
    pacenotes = self.pacenotes:onSerialize(),
    audioMode = self.audioMode,
    version = currentVersion,
  }
end

function C:onDeserialized(data)
  if not data then return end
  if type(data) ~= 'table' then
    log('E', logTag, 'invalid notebook data')
    return
  end

  if not data.version then
    self.version = self.version or currentVersion
  else
    self.version = data.version
  end

  local description = data.description
  if description == nil then description = self.description or "" end
  if type(description) ~= 'string' then description = tostring(description) end

  self.name = data.name or self.name or "Primary"
  self.description = string.gsub(description, "\\n", "\n")
  self.authors = data.authors or self.authors or ""
  self.metadata = type(data.metadata) == 'table' and data.metadata or self.metadata or {}
  self.created_at = data.created_at or self.created_at or os.time()
  self.updated_at = data.updated_at or self.updated_at or self.created_at
  self.audioMode = data.audioMode or self.audioMode or RallyEnums.pacenoteAudioMode.structuredOffline

  local oldIdMap = {}

  self.pacenotes:clear()
  self.pacenotes:onDeserialized(data.pacenotes or {}, oldIdMap)

  if self:isV2() then
    self:upgradeFromV2ToV3()
  end

  -- per-pacenote `notes` is no longer persisted. Both pieces of cache rebuild are
  -- deferred to consumers, because they depend on context that isn't available here:
  --  - refreshAllStructuredNotes() depends on the active text compositor, which is
  --    resolved via _getRallyManagerPick(); during deserialize the editor hasn't
  --    yet registered this notebook as currentPath, so its voicepack pick is
  --    ignored and the wrong style would populate the cache. Editor and
  --    rallyManager invoke it once they've wired up their pick source.
  --  - autofillDistanceCalls() needs the snaproad and is deferred until
  --    setSnaproad() runs.
end

function C:upgradeFromV2ToV3()
  log('I', logTag, 'upgrading '..self.name..' from v2 to v3')
  for _, pacenote in ipairs(self.pacenotes.sorted) do
    pacenote:upgradeFromV2ToV3()
  end

  self.version = "3"

  self:autofillDistanceCalls()
end

function C:allWaypoints()
  local wps = {}
  for i,pacenote in pairs(self.pacenotes.objects) do
    for j,wp in pairs(pacenote.pacenoteWaypoints.objects) do
      wps[wp.id] = wp
    end
  end
  return wps
end

function C:getWaypoint(wpId)
  for i, pacenote in pairs(self.pacenotes.objects) do
    for i, waypoint in pairs(pacenote.pacenoteWaypoints.objects) do
      if waypoint.id == wpId then
        return waypoint
      end
    end
  end
  return nil
end

function C:getLanguages()
  local lang = self:_detectFirstNotesLanguage() or rallyUtil.default_codriver_language
  return { { language = lang, codrivers = {} } }
end

function C:setAllRadii(newRadius, wpType)
  for i, pacenote in pairs(self.pacenotes.objects) do
    pacenote:setAllRadii(newRadius, wpType)
  end
end

function C:allToTerrain()
  for i, pacenote in pairs(self.pacenotes.objects) do
    pacenote:allToTerrain()
  end
end

-- The codriver concept is fully phased out: voicepack persona/language come from voicepack
-- preferences, and there is no per-notebook codriver list. selectedCodriver() returns a
-- synthetic stub so legacy callers still get a sensible language string for note lookups.
-- Returns the first language key found in any pacenote's notes table, or nil.
function C:_detectFirstNotesLanguage()
  for _, pn in ipairs(self.pacenotes.sorted) do
    if pn.notes then
      for lang, _ in pairs(pn.notes) do
        return lang
      end
    end
  end
  return nil
end

function C:selectedCodriver()
  return {
    id = '_auto',
    name = '<auto>',
    language = self:_detectFirstNotesLanguage() or rallyUtil.default_codriver_language,
    voice = rallyUtil.default_codriver_voice,
  }
end

function C:selectedCodriverLanguage()
  local codriver = self:selectedCodriver()
  return codriver.language
end

function C:refreshAllPacenotes()
  self:refreshAllStructuredNotes()
  self:refreshAllFreeformNotes()
end

function C:refreshAllStructuredNotes()
  self.textCompositor = nil -- clear the cached text compositor
  -- custom-audio notebooks don't have a compositor and don't use structured fields for output.
  if self:isAudioModeCustom() then return end
  for _,pacenote in ipairs(self.pacenotes.sorted) do
    pacenote:refreshStructured()
  end
end

function C:refreshAllFreeformNotes()
  for _,pacenote in ipairs(self.pacenotes.sorted) do
    pacenote:refreshFreeform()
  end
end

-- first pacenote needs csImmediate so it fires without waiting for a previous
-- note's distance call; everything else stays on the dynamic default.
function C:autoManageTriggerTypes()
  for i,pn in ipairs(self.pacenotes.sorted) do
    local triggerType = i == 1 and RallyEnums.triggerType.csImmediate or RallyEnums.triggerType.dynamic
    if pn.triggerType ~= triggerType then
      pn:setTriggerType(triggerType)
    end
  end
end

function C:remeasureAllPacenotes()
  local snaproad = self:getSnaproad()
  if not snaproad then return end

  for _, pn in ipairs(self.pacenotes.sorted) do
    if not pn.missing then
      snaproad:setPartitionToPacenote(pn)
      snaproad:measurePartition()
    end
  end
end

function C:refreshPacenotes(opts)
  opts = opts or {}
  local refreshStart = os.clock()

  if opts.cleanupNames ~= false then
    self:cleanupPacenoteNames()
  end
  self:autoManageTriggerTypes()
  if opts.remeasure ~= false then
    self:remeasureAllPacenotes()
  end
  self:autofillDistanceCalls()
  self:refreshAllPacenotes()

  local elapsedMs = math.floor(((os.clock() - refreshStart) * 1000) + 0.5)
  log('D', logTag, string.format('refreshed pacenotes (%dms)', elapsedMs))
end

function C:generateAllFreeform()
  for _,pacenote in ipairs(self.pacenotes.sorted) do
    pacenote:generateFreeformFromStructured()
  end
end

function C:generatePacenotes(corners)
  if not corners or #corners == 0 then
    log('E', logTag, 'generatePacenotes: no corners provided')
    return
  end

  -- Clear existing pacenotes
  self:deleteAllPacenotes()

  -- Get snaproad from editor context
  local snaproad = editor_rallyEditor and editor_rallyEditor.getPacenotesWindow() and editor_rallyEditor.getPacenotesWindow():getSnaproad()
  if not snaproad then
    log('W', logTag, 'generatePacenotes: snaproad not available, waypoint normals and accurate distance calculations will not be available')
  end

  -- Create pacenotes from generated corner groups.
  for i, corner in ipairs(corners) do
    local pn = self.pacenotes:create()
    pn.structured:setSlotItems({
      ["4"] = { type = 'corner' },
    })

    -- Create waypoints
    local locCs = snaproad and snaproad:closestSnapResult(corner.pos, true) or nil
    local locCe = snaproad and snaproad:closestSnapResult(corner.posEnd, true) or nil
    local wp_cs = pn.pacenoteWaypoints:create('corner start', locCs and locCs.pos or vec3(corner.pos))
    local wp_ce = pn.pacenoteWaypoints:create('corner end', locCe and locCe.pos or vec3(corner.posEnd))

    -- Set waypoint normals from snaproad if available
    if snaproad then
      if locCs then
        local normalVec = snaproad:normalForSnapResult(locCs)
        if normalVec then
          wp_cs:setNormal(normalVec)
        end
      end

      if locCe then
        local normalVec = snaproad:normalForSnapResult(locCe)
        if normalVec then
          wp_ce:setNormal(normalVec)
        end
      end
    end

    -- Set sort order
    pn.sortOrder = i * 5
  end

  -- Sort and cleanup
  self.pacenotes:sort()
  self:cleanupPacenoteNames()

  -- Autofill distance calls between pacenotes
  self:autofillDistanceCalls()

  log('I', logTag, 'Generated '..#self.pacenotes.sorted..' pacenotes from '..#corners..' detected corners')
end

function C:autofillDistanceCalls()
  -- first clear everything
  for _,pacenote in ipairs(self.pacenotes.sorted) do
    local before = pacenote:getNoteFieldBefore()
    local after = pacenote:getNoteFieldAfter()
    if before ~= rallyUtil.autofill_blocker and (not pacenote.isolate or before ~= rallyUtil.autodist_internal_level1) then
      pacenote:setNoteFieldBefore('', -1)
    end
    if after ~= rallyUtil.autofill_blocker and (not pacenote.isolate or after ~= rallyUtil.autodist_internal_level1) then
      pacenote:setNoteFieldAfter('', -1)
    end
  end

  for i,pacenote in ipairs(self.pacenotes.sorted) do
    local pn_next = self:findNextNonIsolated(i)

    if not pacenote.isolate and not pacenote.ignoreDistanceCalls and pn_next and not pn_next.missing then
      local compositor = self:getTextCompositor()
      if not compositor then break end
      if compositor:distanceCallsEnabled() then
        local dist = pacenote:distanceCornerEndToCornerStart(pn_next)
        -- snaproad may fail to snap a waypoint that's outside the road; skip the
        -- pair rather than crash. autofill will retry on the next snaproad swap.
        if not dist then break end
        local distStr = compositor:distanceToString(dist)

        -- Decide what to do based on the distance
        local shorthand, hasShorthand = compositor:getDistanceCallShorthand(dist)
        if hasShorthand then
          if pn_next:getNoteFieldBefore() ~= rallyUtil.autofill_blocker then
            local linkWord = pn_next.includeLinkWord == false and rallyUtil.autodist_internal_level1 or (shorthand or rallyUtil.autodist_internal_level1)
            pn_next:setNoteFieldBefore(linkWord, dist)
          end
        else
          if pacenote:getNoteFieldAfter() ~= rallyUtil.autofill_blocker then
            pacenote:setNoteFieldAfter(distStr, dist)
          end
        end
      end
    end
  end
end

function C:findNextNonIsolated(i)
  for j = i + 1, #self.pacenotes.sorted do
    local pn_next = self.pacenotes.sorted[j]
    if pn_next and not pn_next.isolate then
      return pn_next
    end
  end
  return nil
end

function C:onRallySettingsChanged()
  self:invalidateActiveVoicepackCache()
  self.textCompositor = nil
  self.visualCompositor = nil
  self._offlineTextCompositor = nil
  self.pacenoteMetadataOfflineStructured = nil
  self:cacheCompiledPacenotes()
end

function C:cacheCompiledPacenotes()
  self:clearCompilationFailures()
  for i,pn in ipairs(self.pacenotes.sorted) do
    pn.visualSerialNo = i
    pn:clearCachedFgData()
    pn:asCompiled()
    if pn:didCompileFail() then
      log('E', logTag, 'cacheCompiledPacenotes: failed to compile pacenote: '..pn.name)
      -- log('E', logTag, 'cacheCompiledPacenotes: aborting remaining pacenote compilations')
      -- break
    end
  end
end

function C:clearResolvedAudioObjs()
  for _, pn in ipairs(self.pacenotes.sorted) do
    pn:clearResolvedAudioObjs()
  end
end

function C:clearCompilationFailures()
  for _,pn in ipairs(self.pacenotes.sorted) do
    pn:clearCompilationFailures()
  end
end

function C:findNClosestPacenotes(pos, n)
  -- Table to store objects and their distances
  local distances = {}

  -- Calculate each object's distance from the input position and store it
  for _,pacenote in ipairs(self.pacenotes.sorted) do
    local distance = pos:distance(pacenote:getCornerStartWaypoint().pos)  -- using the provided distance method
    table.insert(distances, {pacenote = pacenote, distance = distance})
  end

  -- Sort the objects by distance
  table.sort(distances, function(a, b) return a.distance < b.distance end)

  -- Retrieve the N closest objects
  local closest = {}
  n = math.min(#self.pacenotes.sorted, n)
  for i = 1, n do
    if distances[i] then  -- Ensure there's an object to add
      table.insert(closest, distances[i].pacenote)
    end
  end

  return closest
end

function C:getSystemPacenotesForAudioMode()
  -- Custom mode does not require a text compositor: system pacenotes are resolved by
  -- their internal name (see C:getCustomSystemPacenotesForAudioMode).
  if self:isAudioModeCustom() then
    return self:getCustomSystemPacenotesForAudioMode()
  end

  local missionPacenotesDirname = nil
  local metadata = nil
  if self:isAudioModeFreeform() then
    -- missionPacenotesDirname = self:missionPacenotesDir(rallyUtil.freeformDir)
    -- metadata = self:loadFreeformPacenoteMetadata()
    missionPacenotesDirname = self:missionPacenotesDir(rallyUtil.systemDir)
    metadata = self:loadSystemPacenoteMetadata()
  elseif self:isAudioModeOnlineStructured() then
    -- missionPacenotesDirname = self:missionPacenotesDir(rallyUtil.structuredDir)
    -- metadata = self:loadOnlineStructuredPacenoteMetadata()
    missionPacenotesDirname = self:missionPacenotesDir(rallyUtil.systemDir)
    metadata = self:loadSystemPacenoteMetadata()
  elseif self:isAudioModeOfflineStructured() then
    missionPacenotesDirname = nil
    metadata = self:loadOfflineStructuredPacenoteMetadata()
  else
    log('E', logTag, 'getSystemPacenotesForAudioMode: unknown audio mode')
  end

  local compositor
  if self:isAudioModeOfflineStructured() then
    compositor = self:getOfflineTextCompositor()
  else
    compositor = self:getTextCompositor()
  end

  if not compositor then
    log('E', logTag, 'getSystemPacenotesForAudioMode: no compositor available')
    return {}, nil
  end

  local _, activeVoicepack = self:resolveActiveVoicepack()
  local systemPacenotes = compositor:getSystemPacenotes(
    missionPacenotesDirname,
    self:isAudioModeOfflineStructured() and activeVoicepack or nil
  )
  local customMap = self:resolveAllCustomSystemPacenotes(systemPacenotes)

  if next(customMap) then
    local customMetadata = self:loadCustomSystemPacenoteMetadata()
    if customMetadata then
      metadata = metadata or {}
      for k, v in pairs(customMetadata) do
        metadata[k] = v
      end
    end
  end

  for name, variants in pairs(systemPacenotes) do
    for i, variant in ipairs(variants) do
      local key = name .. '_' .. tostring(i)
      if customMap[key] then
        variant.originalAudioFname = variant.audioFname
        variant.audioFname = customMap[key]
        variant.isCustomAudio = true
      end
    end
  end
  return systemPacenotes, metadata
end

-- Builds system pacenotes (countdowns, warnings, start/finish, etc.) for custom mode
-- without a text compositor. The canonical names/order come from
-- notebook/systemPacenotes.lua; the audio for each is resolved by internal name
-- (pacenote_system_<name>_<variant>.ogg) from the active voicepack's audio dir,
-- falling back to its reuseAudioFrom sources (e.g. a global pack) for any clip the
-- mission pack doesn't ship. Variants are discovered by probing increasing indices.
function C:getCustomSystemPacenotesForAudioMode()
  local _, entry = self:resolveActiveVoicepack()

  local systemPacenotes = {}
  local metadata = {}
  if entry then
    for basename, metadataEntry in pairs(voicepack.getEntryMetadata(entry)) do
      metadata[basename] = metadataEntry
    end

    local transcriptions = self:loadCustomPacenoteTranscriptions() or {}
    for _, name in ipairs(systemPacenoteNames.required) do
      local variants = {}
      local variantIndex = 1
      while true do
        local basename = rallyUtil.makeSystemPacenoteAudioFilename(name, variantIndex)
        local fname = voicepack.getEntryAudioFile(entry, basename)
        if fname and FS:fileExists(fname) then
          local transcription = transcriptions[basename]
          table.insert(variants, {
            name = name,
            audioFname = fname,
            audioBasename = basename,
            text = (transcription and transcription.description) or '',
          })
          variantIndex = variantIndex + 1
        else
          break
        end
      end
      if #variants > 0 then
        systemPacenotes[name] = variants
      end
    end
  end

  -- Mission-local overrides (notebooks/custom/<basename>/) still win when present.
  local customMap = self:resolveAllCustomSystemPacenotes(systemPacenotes)
  if next(customMap) then
    local customMetadata = self:loadCustomSystemPacenoteMetadata()
    if customMetadata then
      for k, v in pairs(customMetadata) do
        metadata[k] = v
      end
    end
  end

  for name, variants in pairs(systemPacenotes) do
    for i, variant in ipairs(variants) do
      local key = name .. '_' .. tostring(i)
      if customMap[key] then
        variant.originalAudioFname = variant.audioFname
        variant.audioFname = customMap[key]
        variant.isCustomAudio = true
      end
    end
  end

  return systemPacenotes, metadata
end

-- function C:getSystemPacenote(name)
--   -- Split the name into prefix and optional id parts
--   local prefix, id
--   if string.find(name, "_") then
--       prefix, id = string.match(name, "^([^_]+)_([^_]*)$")
--   else
--       prefix = name
--       id = nil
--   end
--   if prefix then
--     local id = tonumber(id)
--     if id then
--       return self:getTextCompositor():getSystemPacenote(prefix, id)
--     else
--       log('E', logTag, 'getSystemPacenote: could not parse id: '..id)
--     end
--   else
--     log('E', logTag, 'getSystemPacenote: could not parse name: '..name)
--   end

--   return nil
-- end

function C:getRandomSystemPacenote(desiredPrefix)
  local compositor = self:getTextCompositor()
  local systemPacenotes, metadata = self:getSystemPacenotesForAudioMode()
  local noteSet = systemPacenotes[desiredPrefix]
  if not noteSet then
    log('E', logTag, 'getRandomSystemPacenote: could not find note set for prefix "'..desiredPrefix..'"')
    return nil
  end

  if not metadata then
    log('E', logTag, 'getRandomSystemPacenote: could not find metadata for prefix "'..desiredPrefix..'"')
    return nil
  end

  return compositorUtil.getRandomWeightedItem(noteSet), metadata
end

function C:setAdjacentNotes(pacenote_id)
  local pacenotesSorted = self.pacenotes.sorted
  for i, note in ipairs(pacenotesSorted) do
    if pacenote_id == note.id then
      local prevNote = pacenotesSorted[i-1]
      local nextNote = pacenotesSorted[i+1]
      note:setAdjacentNotes(prevNote, nextNote)
    else
      note:clearAdjacentNotes()
    end
  end
end

function C:setAllAdjacentNotes()
  local pacenotesSorted = self.pacenotes.sorted
  for i, note in ipairs(pacenotesSorted) do
    note:clearAdjacentNotes()
  end

  for i, note in ipairs(pacenotesSorted) do
    local prevNote = pacenotesSorted[i-1]
    local nextNote = pacenotesSorted[i+1]
    note:setAdjacentNotes(prevNote, nextNote)
  end
end

function C:markAllTodo()
  for _,pn in ipairs(self.pacenotes.sorted) do
    pn:markTodo()
  end
end

function C:clearAllTodo()
  for _,pn in ipairs(self.pacenotes.sorted) do
    pn:clearTodo()
  end
end

function C:markRestTodo(pacenote)
  if not pacenote then return end

  local hitPacenote = false
  for _,pn in ipairs(self.pacenotes.sorted) do
    if pn.id == pacenote.id then
      hitPacenote = true
    end
    if hitPacenote then
      pn:markTodo()
    end
  end
end

function C:getAudioMode()
  -- audioMode is a persisted property of the notebook itself; the active voicepack pick
  -- does not override it.
  if self.audioMode then return self.audioMode end
  local voicepack = self:resolveActiveVoicepack()
  if voicepack and voicepack ~= '' then
    return RallyEnums.pacenoteAudioMode.structuredOffline
  end
  return nil
end

function C:setAudioMode(mode)
  self.audioMode = mode
end

function C:isAudioModeOnlineStructured()
  return self:getAudioMode() == RallyEnums.pacenoteAudioMode.structuredOnline
end

function C:isAudioModeOfflineStructured()
  return self:getAudioMode() == RallyEnums.pacenoteAudioMode.structuredOffline
end

function C:isAudioModeFreeform()
  return self:getAudioMode() == RallyEnums.pacenoteAudioMode.freeform
end

function C:isAudioModeCustom()
  return self:getAudioMode() == RallyEnums.pacenoteAudioMode.custom
end

function C:useStructured()
  return self:getAudioMode() == RallyEnums.pacenoteAudioMode.structuredOffline or
         self:getAudioMode() == RallyEnums.pacenoteAudioMode.structuredOnline
end

function C:isV2()
  return not self.version or self.version == "2" or self.version == 2
end

function C:isV3()
  return self.version == "3" or self.version == 3
end

function C:missionPacenotesDir(audioModeDir)
  if not audioModeDir then
    log('E', logTag, 'missionPacenotesDir: audioModeDir is nil')
    return nil
  end

  local missionDir = self:getMissionDir()
  local notebookBasename = rallyUtil.normalizeName(self:basenameNoExt()) or 'none'

  return table.concat({
    missionDir,
    rallyUtil.notebooksPath,
    rallyUtil.generatedPacenotesDir,
    notebookBasename,
    audioModeDir
  }, '/')
end

-- Finds the mission-scoped voicepack entry that owns this notebook (its `notebooks`
-- list contains this notebook's basename). Custom corner clips belong to that specific
-- mission voicepack, not to whatever global pack the preference-driven active pick may
-- resolve to. Returns nil if no mission voicepack claims this notebook.
function C:missionVoicepackEntryForNotebook()
  local missionDir = self:getMissionDir()
  if not missionDir then return nil end
  local basename = rallyUtil.normalizeName(self:basenameNoExt() or '')
  if not basename then return nil end
  local index = voicepack.scanMission(missionDir, self:getMissionId())
  for _, entry in pairs(index) do
    if type(entry.notebooks) == 'table' then
      for _, nb in ipairs(entry.notebooks) do
        if rallyUtil.normalizeName(nb) == basename then
          return entry
        end
      end
    end
  end
  return nil
end

-- The voicepack entry that owns this notebook's custom audio. Prefers the mission
-- voicepack that lists this notebook; falls back to the active voicepack only when no
-- mission voicepack claims it. This keeps the custom-audio widget scoped to the
-- mission-specific pack and out of any global/source pack's audio.
function C:customAudioEntry()
  return self:missionVoicepackEntryForNotebook() or select(2, self:resolveActiveVoicepack())
end

-- Returns the directory holding `pacenote_*.ogg` (and metadata.json) for the custom
-- audio owner voicepack (the mission voicepack that owns this notebook). Returns nil
-- when no owner voicepack is resolvable.
function C:customPacenotesDir()
  local entry = self:customAudioEntry()
  if entry and entry.dir then return entry.dir end
  return nil
end

-- Audio (.ogg) files live in the voicepack's `audio/` subdir; metadata/transcriptions
-- stay at the voicepack root.
function C:customPacenotesAudioDir()
  local root = self:customPacenotesDir()
  if not root then return nil end
  return root .. '/' .. voicepack.audioSubdir
end

-- Returns the sorted list of custom-audio clip basenames present on disk in the
-- owner mission voicepack's audio dir. Order is the filename sort (clips are exported
-- in increasing numerical order); the number is used only for ordering, never to match
-- a clip to a specific pacenote. System pacenotes (pacenote_system_*) are excluded
-- by the numeric-prefix pattern.
function C:scanCustomAudioBasenames()
  if self._scannedCustomAudioBasenames then return self._scannedCustomAudioBasenames end
  local dir = self:customPacenotesAudioDir()
  local out = {}
  if dir and FS:directoryExists(dir) then
    local files = FS:findFiles(dir, 'pacenote_*.ogg', 0, true, false) or {}
    for _, full in ipairs(files) do
      local base = string.match(full, "([^/\\]+)$") or full
      if rallyUtil.customPacenoteAudioBasenameParts(base) then
        table.insert(out, base)
      end
    end
    table.sort(out, rallyUtil.compareCustomPacenoteAudioBasenames)
  end
  self._scannedCustomAudioBasenames = out
  return out
end

-- Resolves a clip basename to a full path via the custom audio owner voicepack,
-- honouring reuseAudioFrom fallback to a source pack.
function C:resolveCustomAudioBasename(basename)
  if not basename then return nil end
  local entry = self:customAudioEntry()
  if not entry then return nil end
  return voicepack.getEntryAudioFile(entry, basename)
end

local function clampInt(v, minVal, maxVal)
  if v < minVal then return minVal end
  if v > maxVal then return maxVal end
  return v
end

-- Returns anchor metadata keyed by basename plus the ordered anchor points. Anchors
-- are user-provided landmarks: this audio clip belongs on this pacenote.
function C:getCustomAudioAnchorInfo()
  local sorted = self.pacenotes and self.pacenotes.sorted or {}
  local disk = self:scanCustomAudioBasenames()
  local diskIndex = {}
  for i, base in ipairs(disk) do diskIndex[base] = i end

  local points = {}
  local byBasename = {}

  for _, pn in ipairs(sorted) do
    for _, base in ipairs(pn.customAudioAnchors or {}) do
      local audioIndex = diskIndex[base]
      if audioIndex then
        if byBasename[base] then
          byBasename[base].duplicate = true
          byBasename[base].invalid = true
        else
          local point = {
            basename = base,
            audioIndex = audioIndex,
            noteIndex = pn.sortOrder,
            pacenote = pn,
          }
          byBasename[base] = {
            anchored = true,
            basename = base,
            audioIndex = audioIndex,
            noteIndex = pn.sortOrder,
            pacenote = pn,
            invalid = false,
          }
          table.insert(points, point)
        end
      end
    end
  end

  table.sort(points, function(a, b) return a.audioIndex < b.audioIndex end)
  for i = 2, #points do
    local prev = points[i - 1]
    local curr = points[i]
    if curr.noteIndex < prev.noteIndex then
      byBasename[prev.basename].invalid = true
      byBasename[curr.basename].invalid = true
      byBasename[prev.basename].nonMonotonic = true
      byBasename[curr.basename].nonMonotonic = true
    end
  end

  return { points = points, byBasename = byBasename }
end

-- Computes the assignment of clip basenames to pacenotes from manual anchors. Clips
-- between anchor points are interpolated between those landmark pacenotes.
function C:getCustomAudioAssignment()
  local sorted = self.pacenotes and self.pacenotes.sorted or {}
  local disk = self:scanCustomAudioBasenames()
  local assignment = {}
  for _, pn in ipairs(sorted) do assignment[pn.id] = {} end

  local noteCount = #sorted
  if noteCount == 0 then return assignment end

  local info = self:getCustomAudioAnchorInfo()
  local anchors = {
    { audioIndex = 0, noteIndex = 0 },
  }
  for _, point in ipairs(info.points) do
    table.insert(anchors, point)
  end
  table.insert(anchors, { audioIndex = #disk + 1, noteIndex = noteCount + 1 })

  local anchorAtAudioIndex = {}
  for _, point in ipairs(info.points) do
    anchorAtAudioIndex[point.audioIndex] = point.noteIndex
  end

  local anchorCursor = 1
  for _, base in ipairs(disk) do
    local audioIndex = nil
    -- disk is small, but keep the index lookup explicit and deterministic.
    for i, diskBase in ipairs(disk) do
      if diskBase == base then audioIndex = i break end
    end

    while anchors[anchorCursor + 1] and audioIndex > anchors[anchorCursor + 1].audioIndex do
      anchorCursor = anchorCursor + 1
    end

    local noteIndex = anchorAtAudioIndex[audioIndex]
    if not noteIndex then
      local left = anchors[anchorCursor]
      local right = anchors[anchorCursor + 1]
      local denom = math.max(right.audioIndex - left.audioIndex, 1)
      local t = (audioIndex - left.audioIndex) / denom
      noteIndex = math.floor(left.noteIndex + t * (right.noteIndex - left.noteIndex) + 0.5)
    end

    noteIndex = clampInt(noteIndex, 1, noteCount)
    local owner = sorted[noteIndex]
    if owner then
      table.insert(assignment[owner.id], base)
    end
  end

  return assignment
end

function C:customAudioBasenamesFor(pacenote)
  if not pacenote then return {} end
  return self:getCustomAudioAssignment()[pacenote.id] or {}
end

function C:invalidateCustomAudioMapping()
  self._customAudioMapping = nil
  self._scannedCustomAudioBasenames = nil
  self.pacenoteMetadataCustom = nil
  self.pacenoteTranscriptionsCustom = nil
end

function C:customAudioAnchorInfoFor(basename)
  return self:getCustomAudioAnchorInfo().byBasename[basename]
end

function C:canSetCustomAudioAnchor(pacenote, basename)
  if not pacenote or not basename then return false, 'missing pacenote or audio clip' end
  local disk = self:scanCustomAudioBasenames()
  local candidateAudioIndex = nil
  for i, base in ipairs(disk) do
    if base == basename then candidateAudioIndex = i break end
  end
  if not candidateAudioIndex then return false, 'audio clip is not in the mission voicepack' end

  local candidateNoteIndex = pacenote.sortOrder
  local info = self:getCustomAudioAnchorInfo()
  for _, point in ipairs(info.points) do
    if point.basename ~= basename then
      if point.audioIndex < candidateAudioIndex and point.noteIndex > candidateNoteIndex then
        return false, 'would put a later pacenote before an earlier audio anchor'
      end
      if point.audioIndex > candidateAudioIndex and point.noteIndex < candidateNoteIndex then
        return false, 'would put an earlier pacenote after a later audio anchor'
      end
    end
  end

  return true
end

function C:setCustomAudioAnchor(pacenote, basename)
  if not pacenote or not basename then return false end
  local ok = self:canSetCustomAudioAnchor(pacenote, basename)
  if not ok then return false end
  for _, pn in ipairs(self.pacenotes.sorted) do
    if pn.customAudioAnchors then
      for i = #pn.customAudioAnchors, 1, -1 do
        if pn.customAudioAnchors[i] == basename then table.remove(pn.customAudioAnchors, i) end
      end
      if #pn.customAudioAnchors == 0 then pn.customAudioAnchors = nil end
    end
  end
  pacenote.customAudioAnchors = pacenote.customAudioAnchors or {}
  table.insert(pacenote.customAudioAnchors, basename)
  self:invalidateCustomAudioMapping()
  for _, pn in ipairs(self.pacenotes.sorted) do
    if pn.clearCachedFgData then pn:clearCachedFgData() end
  end
  return true
end

function C:clearCustomAudioAnchor(basename)
  if not basename then return false end
  local changed = false
  for _, pn in ipairs(self.pacenotes.sorted) do
    if pn.customAudioAnchors then
      for i = #pn.customAudioAnchors, 1, -1 do
        if pn.customAudioAnchors[i] == basename then
          table.remove(pn.customAudioAnchors, i)
          changed = true
        end
      end
      if #pn.customAudioAnchors == 0 then pn.customAudioAnchors = nil end
    end
  end
  if changed then
    self:invalidateCustomAudioMapping()
    for _, pn in ipairs(self.pacenotes.sorted) do
      if pn.clearCachedFgData then pn:clearCachedFgData() end
    end
  end
  return changed
end

-- Reconcile after a Reaper re-export: refresh the disk scan and drop anchors whose
-- files no longer exist.
function C:syncCustomAudioFromDisk()
  self:invalidateCustomAudioMapping()
  local disk = self:scanCustomAudioBasenames()
  local diskSet = {}
  for _, b in ipairs(disk) do diskSet[b] = true end
  for _, pn in ipairs(self.pacenotes.sorted) do
    if pn.customAudioAnchors then
      local kept = {}
      for _, b in ipairs(pn.customAudioAnchors) do
        if diskSet[b] then table.insert(kept, b) end
      end
      pn.customAudioAnchors = (#kept > 0) and kept or nil
    end
  end
  self:invalidateCustomAudioMapping()
  for _, pn in ipairs(self.pacenotes.sorted) do
    if pn.clearCachedFgData then pn:clearCachedFgData() end
  end
end

-- Path for mission-local system pacenote overrides (countdowns etc). Out-of-scope for the
-- mission-voicepack refactor; kept on the old `notebooks/custom/<basename>/` layout for now.
function C:customPacenotesBaseDir()
  local missionDir = self:getMissionDir()
  local notebookBasename = rallyUtil.normalizeName(self:basenameNoExt()) or 'none'
  return missionDir .. '/' .. rallyUtil.notebooksPath .. '/custom/' .. notebookBasename
end

function C:resolveAllCustomSystemPacenotes(systemPacenotes)
  if self._customSystemPacenoteCache then
    return self._customSystemPacenoteCache
  end
  local cache = {}
  local missionDir = self:customPacenotesBaseDir()
  for name, variants in pairs(systemPacenotes) do
    local singleVariant = #variants == 1
    for i, _ in ipairs(variants) do
      local key = name .. '_' .. tostring(i)
      local fnames = { key .. '.ogg' }
      if singleVariant then
        table.insert(fnames, name .. '.ogg')
      end
      for _, fname in ipairs(fnames) do
        local sharedPath = sharedCustomSystemDir .. '/' .. fname
        if FS:fileExists(sharedPath) then cache[key] = sharedPath end
        local missionPath = missionDir .. '/' .. fname
        if FS:fileExists(missionPath) then cache[key] = missionPath end
      end
    end
  end
  self._customSystemPacenoteCache = cache
  return cache
end

function C:clearCustomSystemPacenoteCache()
  self._customSystemPacenoteCache = nil
  self._customSystemPacenoteMetadata = nil
end

function C:loadCustomSystemPacenoteMetadata()
  if self._customSystemPacenoteMetadata then
    return self._customSystemPacenoteMetadata
  end
  local merged = {}
  local sharedMetaPath = sharedCustomSystemDir .. '/' .. rallyUtil.pacenotesMetadataBasename
  local sharedMeta = jsonReadFile(sharedMetaPath)
  if sharedMeta then
    for k, v in pairs(sharedMeta) do
      merged[k] = v
    end
  end
  local missionMetaPath = self:customPacenotesBaseDir() .. '/' .. rallyUtil.pacenotesMetadataBasename
  local missionMeta = jsonReadFile(missionMetaPath)
  if missionMeta then
    for k, v in pairs(missionMeta) do
      merged[k] = v
    end
  end
  self._customSystemPacenoteMetadata = merged
  return merged
end

function C:missionPacenoteAudioFile(audioModeDir, pacenoteTextOut)
  local pacenotesDir = self:missionPacenotesDir(audioModeDir)
  local compositor = self:getTextCompositor()
  if not compositor then return nil end
  local pacenoteHash = compositor:pacenoteHash(pacenoteTextOut)
  return pacenotesDir..'/'..rallyUtil.makePacenoteAudioFilename(pacenoteHash)
end

function C:_missionPacenoteMetadataFile(audioModeDir)
  local pacenotesDir = self:missionPacenotesDir(audioModeDir)
  return pacenotesDir..'/'..rallyUtil.pacenotesMetadataBasename
end

local function readMetadataFile(fname)
  local json = jsonReadFile(fname)
  if not json then
    -- uncomment this when needing to debug metadata file issues. otherwise its too noisy.
    -- log('E', logTag, 'couldnt find metadata file: '..fname)
    return nil
  end
  return json
end

function C:loadCustomPacenoteMetadata()
  if self.pacenoteMetadataCustom then
    return self.pacenoteMetadataCustom
  end
  local dir = self:customPacenotesDir()
  if not dir then
    self.pacenoteMetadataCustom = {}
    return self.pacenoteMetadataCustom
  end
  local metadataFnameCustom = dir..'/'..rallyUtil.pacenotesMetadataBasename
  self.pacenoteMetadataCustom = readMetadataFile(metadataFnameCustom) or {}
  return self.pacenoteMetadataCustom
end

function C:loadCustomPacenoteTranscriptions()
  if self.pacenoteTranscriptionsCustom then
    return self.pacenoteTranscriptionsCustom
  end
  local dir = self:customPacenotesDir()
  if not dir then
    self.pacenoteTranscriptionsCustom = {}
    return self.pacenoteTranscriptionsCustom
  end
  local transcriptionsFnameCustom = dir..'/'..rallyUtil.pacenotesTranscriptionsBasename
  self.pacenoteTranscriptionsCustom = readMetadataFile(transcriptionsFnameCustom) or {}
  return self.pacenoteTranscriptionsCustom
end

function C:loadOfflineStructuredPacenoteMetadata()
  local _, voicepackEntry = self:resolveActiveVoicepack()
  local cacheKey = voicepackEntry and voicepackEntry.id or '<none>'
  if self.pacenoteMetadataOfflineStructured and self._pacenoteMetadataOfflineStructuredKey == cacheKey then
    return self.pacenoteMetadataOfflineStructured
  end
  if not voicepackEntry then
    self.pacenoteMetadataOfflineStructured = {}
    self._pacenoteMetadataOfflineStructuredKey = cacheKey
    return self.pacenoteMetadataOfflineStructured
  end
  self.pacenoteMetadataOfflineStructured = voicepack.getEntryMetadata(voicepackEntry) or {}
  self._pacenoteMetadataOfflineStructuredKey = cacheKey
  return self.pacenoteMetadataOfflineStructured
end

function C:loadOnlineStructuredPacenoteMetadata()
  if self.pacenoteMetadataOnlineStructured then
    return self.pacenoteMetadataOnlineStructured
  end
  local metadataFnameOnlineStructured = self:_missionPacenoteMetadataFile(rallyUtil.structuredDir)
  self.pacenoteMetadataOnlineStructured = readMetadataFile(metadataFnameOnlineStructured)
  return self.pacenoteMetadataOnlineStructured
end

function C:loadFreeformPacenoteMetadata()
  if self.pacenoteMetadataFreeform then
    return self.pacenoteMetadataFreeform
  end
  local metadataFnameFreeform = self:_missionPacenoteMetadataFile(rallyUtil.freeformDir)
  self.pacenoteMetadataFreeform = readMetadataFile(metadataFnameFreeform)
  return self.pacenoteMetadataFreeform
end

function C:loadSystemPacenoteMetadata()
  if self.pacenoteMetadataSystem then
    return self.pacenoteMetadataSystem
  end
  local metadataFnameSystem = self:_missionPacenoteMetadataFile(rallyUtil.systemDir)
  self.pacenoteMetadataSystem = readMetadataFile(metadataFnameSystem)
  return self.pacenoteMetadataSystem
end

function C:clearPacenoteAudioModeOverrides()
  for _, pacenote in ipairs(self.pacenotes.sorted) do
    pacenote:setAudioMode(RallyEnums.pacenoteAudioMode.auto)
  end
end

function C:useCodriver(codriver)
  -- codriver pick is no longer persisted per-mission; this just clears caches so any
  -- future changes (e.g. language) get picked up.
  self:clearCompilationFailures()
end

function C:deletePacenoteLanguage(lang)
  for _, pacenote in ipairs(self.pacenotes.sorted) do
    pacenote:deleteLanguage(lang)
  end
end

return function(...)
  local o = {}

  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
