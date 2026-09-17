-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local logTag = ''
local cc = require('/lua/ge/extensions/gameplay/rally/util/colors')
local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local Snaproad = require('/lua/ge/extensions/gameplay/rally/snaproad')
-- local Recce = require('/lua/ge/extensions/gameplay/rally/recce')
local RallyEnums = require('/lua/ge/extensions/gameplay/rally/enums')
local PacenoteForm = require('/lua/ge/extensions/editor/rallyEditor/pacenotes/pacenoteForm')
local CustomAudioList = require('/lua/ge/extensions/editor/rallyEditor/pacenotes/customAudioList')
local SelectedPacenoteUtility = require('/lua/ge/extensions/editor/rallyEditor/pacenotes/selectedPacenoteUtility')
local GhostNotebookRenderer = require('/lua/ge/extensions/editor/rallyEditor/ghostNotebook/ghostRenderer')
local NoSelectionPreview = require('/lua/ge/extensions/gameplay/rally/notebook/noSelectionPreview')
local RallyManager = require('/lua/ge/extensions/gameplay/rally/rallyManager')
local AudioManager = require('/lua/ge/extensions/gameplay/rally/audioManager')
local zSnap = require('/lua/ge/extensions/editor/rallyEditor/zSnap')
local TrafficExclusion = require('/lua/ge/extensions/gameplay/rally/trafficExclusion')
-- local Driveline = require('/lua/ge/extensions/gameplay/rally/driveline')
local DrivelineV3 = require('/lua/ge/extensions/gameplay/rally/driveline/drivelineV3')
local DrivelineEditSurface = require('/lua/ge/extensions/editor/rallyEditor/drivelineEditSurface')

-- pacenote form fields
-- local pacenoteNameText = im.ArrayChar(1024, "")
-- local playbackRulesText = im.ArrayChar(1024, "")

-- waypoint form fields
-- local waypointNameText = im.ArrayChar(1024, "")
-- local waypointPosition = im.ArrayFloat(3)
-- local waypointNormal = im.ArrayFloat(3)
-- local waypointRadius = im.FloatPtr(0)

local pacenotesSearchText = im.ArrayChar(1024, "")
local drivelineReprojectDebounceSecs = 0.15
local pacenotesListClipper = im.ImGuiListClipper()
local emptyNotebookCreateHint = "Hold Ctrl and click the snaproad to create the first pacenote."

local C = {}
C.windowDescription = 'Pacenotes'

local function selectWaypointUndo(data)
  data.self:selectWaypoint(data.old)
end
local function selectWaypointRedo(data)
  data.self:selectWaypoint(data.new)
end

local editModes = {
  editAll = 'edit_all',
  editCorners = 'edit_corners',
}

local function newPacenoteToolsState()
  return {
    insertMode = false,
    snaproad = nil,
    mode = nil,
    search = nil,
    internalLock = false,
    hover_wp_id = nil,
    shift = false,
    selected_pn_id = nil,
    selected_wp_id = nil,
    recent_selected_pn_id = nil,
    playbackLastCameraPos = nil,
    last_camera = {
      pos = nil,
      quat = nil,
      name = nil  -- track camera mode name
    },
    pulseTime = 0,  -- accumulated time for pulsating waypoint effect
    showMeasurements = false,
    drivelineEditActive = false,
  }
end

local function createBoundsForPartition(snaproad, partition)
  if not (snaproad and partition) then return nil end

  local minGap = snaproad:minAdjacentWaypointDistance()
  local lowerDist = partition.limitBackLocation and (partition.limitBackLocation.distanceAlongRoute + minGap) or 0
  local upperDist = partition.limitFwdLocation and (partition.limitFwdLocation.distanceAlongRoute - minGap) or snaproad:totalRouteLength()
  if upperDist - lowerDist < minGap then return nil end

  return lowerDist, upperDist, minGap
end

local function partitionForCreateLocation(snaproad, loc)
  if not (snaproad and loc and loc.distanceAlongRoute) then return nil end

  local state = snaproad.partition_all_state
  local partitions = state and state.partitions
  if not partitions then return nil end

  for _,partition in ipairs(partitions) do
    local lowerDist, upperDist, minGap = createBoundsForPartition(snaproad, partition)
    if lowerDist and loc.distanceAlongRoute >= lowerDist and loc.distanceAlongRoute <= upperDist - minGap then
      return partition, lowerDist, upperDist, minGap
    end
  end

  return nil
end

function C:init(rallyEditor)
  self.rallyEditor = rallyEditor
  self.mouseInfo = {}

  self.wasWPSelected = false

  self.notes_valid = true
  self.invalid_notes_count = 0
  self.todo_count = 0
  self.validation_issues = {}
  self.validationDirty = true

  self.pacenoteToolsState = newPacenoteToolsState()

  self.pacenoteForm = PacenoteForm(self)
  self.ghostNotebookRenderer = GhostNotebookRenderer(rallyEditor)
  self.pacenotesDrivelineHost = nil
  self.drivelineEditSnapshot = nil
  self.drivelineLiveReprojectDirty = false
  self.drivelineLiveReprojectAt = nil
  self.pacenoteDrivelineInputBlocked = false
  self.pacenoteWaypointDragActive = false
  self.customAudioAnchorPick = nil
  self.previewAudioManager = nil
  self.previewAudioManagerNotebook = nil
  self.previewAudioActive = false
end

function C:clearState()
  self:stopPreviewAudio()

  self.path = nil
  self.mouseInfo = {}
  self.wasWPSelected = false
  self.notes_valid = true
  self.invalid_notes_count = 0
  self.todo_count = 0
  self.validation_issues = {}
  self.validationDirty = true
  self.pacenoteToolsState = newPacenoteToolsState()
  self.simpleDragMouseOffset = nil
  self.beginSimpleDragNoteData = nil
  self.beginDragNoteData = nil
  self.beginDragRotation = nil
  self.beginDragRadius = nil
  self.deleteAllPopup = nil
  self.pacenotesDrivelineHost = nil
  self.drivelineEditSnapshot = nil
  self.drivelineLiveReprojectDirty = false
  self.drivelineLiveReprojectAt = nil
  self.pacenoteDrivelineInputBlocked = false
  self.pacenoteWaypointDragActive = false
  self.customAudioAnchorPick = nil
  self.previewAudioManager = nil
  self.previewAudioManagerNotebook = nil
  self.previewAudioActive = false
  pacenotesSearchText = im.ArrayChar(1024, "")

  if self.pacenoteForm then
    self.pacenoteForm.pacenoteToolsState = self.pacenoteToolsState
    if self.pacenoteForm.clearState then
      self.pacenoteForm:clearState()
    else
      self.pacenoteForm:setPacenote(nil)
    end
  end
end

function C:isValid()
  self:ensureValidationFresh()
  return self.notes_valid and #self.validation_issues == 0
end

function C:invalidateNoSelectionPreview()
  if self.pacenoteToolsState then
    NoSelectionPreview.invalidate(self.pacenoteToolsState)
  end
end

function C:markPacenoteGeometryDirty()
  self:invalidateNoSelectionPreview()
end

function C:setPath(path)
  if self.path ~= path then
    self:stopPreviewAudio()
    self.pacenotesDrivelineHost = nil
    self.drivelineEditSnapshot = nil
    self.drivelineLiveReprojectDirty = false
    self.drivelineLiveReprojectAt = nil
    self:markPacenoteGeometryDirty()
  end
  self.path = path
  self:markValidationDirty()
end

function C:onEditModeActivate()
  self:selectPacenote(self.pacenoteToolsState.selected_pn_id)
end

function C:onEditModeDeactivate()
  self:stopPreviewAudio()
  self.rallyEditor.setFreeCam()
end

function C:getRacePath()
  return editor_raceEditor.getCurrentPath()
end

-- function C:selectionString()
--   local pn = self:selectedPacenote()
--   local wp = self:selectedWaypoint()
--   local text = {}
--   local mode = '--'
--   if pn and not pn.missing then
--     mode = 'P-'
--     local p_txt = '"' .. pn:noteTextForDrawDebug() .. '" ('.. pn.name ..')'
--     table.insert(text, p_txt)
--     if wp and not wp.missing then
--       mode = 'PW'
--       local w_txt = wp:selectionString()
--       table.insert(text, w_txt)
--     end
--   end
--   return text, mode
-- end

function C:selectedPacenote()
  if not self.path then return nil end
  if self.pacenoteToolsState.selected_pn_id then
    return self.path.pacenotes.objects[self.pacenoteToolsState.selected_pn_id]
  else
    return nil
  end
end

function C:selectedWaypoint()
  if not self:selectedPacenote() then return nil end
  if self.pacenoteToolsState.selected_wp_id then
    if self:selectedPacenote().pacenoteWaypoints then
      return self:selectedPacenote().pacenoteWaypoints.objects[self.pacenoteToolsState.selected_wp_id]
    else
      return nil
    end
  else
    return nil
  end
end

function C:ensurePreviewAudioManager()
  if not self.path then return nil end

  if not self.previewAudioManager or self.previewAudioManagerNotebook ~= self.path then
    if self.previewAudioManager then
      self.previewAudioManager:resetQueue()
    end
    self.previewAudioManager = AudioManager({ notebook = self.path })
    self.previewAudioManagerNotebook = self.path
  end

  return self.previewAudioManager
end

function C:startPreviewAudio(pacenote)
  if not pacenote then return false end

  local audioManager = self:ensurePreviewAudioManager()
  if not audioManager then return false end

  audioManager:resetQueue()
  local audioObjs = pacenote:audioObjsFresh()
  if not audioObjs or #audioObjs == 0 then
    self.previewAudioActive = false
    return false
  end

  if gameplay_rally and gameplay_rally.getDebugLogging and gameplay_rally.getDebugLogging() then
    local basenames = {}
    for _, audioObj in ipairs(audioObjs) do
      local fname = audioObj and audioObj.pacenoteFname or ''
      table.insert(basenames, tostring(string.match(fname, "([^/\\]+)$") or fname))
    end
    log('D', logTag, string.format(
      'previewAudio pacenote id=%s name=%s audio=%s',
      tostring(pacenote.id),
      tostring(pacenote.name),
      table.concat(basenames, ', ')
    ))
  end

  audioManager:enqueueAudioObjs(audioObjs)

  local queueInfo = audioManager:getQueueInfo()
  self.previewAudioActive = queueInfo.queueSize > 0 or audioManager:isPlaying()
  return self.previewAudioActive
end

function C:stopPreviewAudio()
  if self.previewAudioManager then
    self.previewAudioManager:resetQueue()
  end
  self.previewAudioActive = false
end

function C:updatePreviewAudio(dtReal, dtSim, dtRaw)
  if not self.previewAudioActive then return end

  local audioManager = self.previewAudioManager
  if not audioManager then
    self.previewAudioActive = false
    return
  end

  if not self:cameraPathIsPlaying() then
    self:stopPreviewAudio()
    return
  end

  audioManager:onUpdate(dtReal, dtSim, dtRaw)

  local queueInfo = audioManager:getQueueInfo()
  if queueInfo.queueSize == 0 and queueInfo.paused then
    self.previewAudioActive = false
  end
end

function C:beginCustomAudioAnchorPick(basename)
  if not basename then return end
  self.customAudioAnchorPick = {
    basename = basename,
    hover_wp_id = nil,
    blockedReason = nil,
    blockedPacenoteId = nil,
    ignoreMouseDown = true,
  }
  if self.pacenoteToolsState then
    self.pacenoteToolsState.hover_wp_id = nil
  end
end

function C:cancelCustomAudioAnchorPick()
  self.customAudioAnchorPick = nil
  if self.pacenoteToolsState then
    self.pacenoteToolsState.hover_wp_id = nil
  end
end

function C:isCustomAudioAnchorPickActive()
  return self.customAudioAnchorPick and self.customAudioAnchorPick.basename ~= nil
end

function C:getCustomAudioAnchorPickBasename()
  return self.customAudioAnchorPick and self.customAudioAnchorPick.basename or nil
end

function C:isPickingCustomAudioAnchorFor(basename)
  return basename ~= nil and self:getCustomAudioAnchorPickBasename() == basename
end

function C:getSnaproad()
  return self.pacenoteToolsState.snaproad
end

function C:loadSnaproad(snapshot)
  local missionDir = self.path:getMissionDir()

  -- Create DrivelineV3 instance and load saved spline-first driveline
  local drivelineV3 = DrivelineV3(missionDir)

  if not drivelineV3:loadDrivelineFromFile() then
    log('E', logTag, 'Failed to load driveline. Please create and save a driveline in the Driveline tab first.')
    self.pacenoteToolsState.snaproad = nil
    return
  end

  -- Get PointList for snaproad
  local pointList = drivelineV3:getFinalPointList()
  if not pointList then
    log('E', logTag, 'Failed to create PointList')
    self.pacenoteToolsState.snaproad = nil
    return
  end

  -- Create snaproad with PointList
  local previousSnaproad = self.pacenoteToolsState.snaproad
  self.pacenoteToolsState.snaproad = Snaproad(pointList)

  -- Hand it to the notebook so distance calculations (and the deferred autofill)
  -- can find it via self.path:getSnaproad() rather than this editor singleton.
  if self.path then
    self.path:setSnaproad(self.pacenoteToolsState.snaproad)
    self:markPacenoteGeometryDirty()
    self:markValidationDirty()
    if previousSnaproad or snapshot then
      self.pacenoteToolsState.snaproad:reprojectPacenoteWaypoints(self.path, previousSnaproad, snapshot)
    end
  end

  log('I', logTag, 'Successfully loaded snaproad with DrivelineV3')
end

function C:isPacenotesDrivelineEditActive()
  return self.pacenoteToolsState and self.pacenoteToolsState.drivelineEditActive
end

function C:_newPacenotesDrivelineHost()
  return {
    path = self.path,
    rallyEditor = self.rallyEditor,
    drivelineLoaded = false,
    loadError = nil,
    loadMode = nil,
    drivelineV3 = nil,
    isSplineView = true,
    showRawPoints = false,
    showFinalDrivelineVisualization = false,
    selectedNodeIdx = 1,
    dragState = nil,
    deletePressed = false,
  }
end

function C:ensurePacenotesDrivelineHost()
  if not self.path then return nil end

  if not self.pacenotesDrivelineHost or self.pacenotesDrivelineHost.path ~= self.path then
    self.pacenotesDrivelineHost = self:_newPacenotesDrivelineHost()
  end

  local host = self.pacenotesDrivelineHost
  if host.drivelineLoaded and host.drivelineV3 then
    return host
  end

  local missionDir = self.path:getMissionDir()
  if not missionDir then
    host.loadError = "No mission directory"
    return nil
  end

  host.drivelineV3 = DrivelineV3(missionDir)
  if not host.drivelineV3:loadDrivelineFromFile() then
    host.loadError = "Failed to load driveline"
    log('E', logTag, 'Failed to load driveline for Pacenotes driveline edit mode')
    return nil
  end
  host.drivelineLoaded = true
  host.loadMode = 'final'
  host.loadError = nil
  return host
end

function C:captureDrivelineEditSnapshot()
  if not self.path or not self.path.pacenotes then return nil end

  local snapshot = {
    pacenotes = {},
    snaproad = self.pacenoteToolsState.snaproad,
  }

  for _,pn in ipairs(self.path.pacenotes.sorted) do
    if not pn.missing then
      local wpCs = pn:getCornerStartWaypoint()
      local wpCe = pn:getCornerEndWaypoint()
      if wpCs and wpCe then
        local csLoc = snapshot.snaproad and snapshot.snaproad:closestSnapResult(wpCs.pos, true) or nil
        local ceLoc = snapshot.snaproad and snapshot.snaproad:closestSnapResult(wpCe.pos, true) or nil
        snapshot.pacenotes[pn.id] = {
          cs = {
            wpId = wpCs.id,
            pos = vec3(wpCs.pos),
            normal = wpCs.normal and vec3(wpCs.normal) or nil,
            location = csLoc and {
              distanceAlongRoute = csLoc.distanceAlongRoute,
              segmentIndex = csLoc.segmentIndex,
              xnorm = csLoc.xnorm,
              pos = vec3(csLoc.pos),
            } or nil,
          },
          ce = {
            wpId = wpCe.id,
            pos = vec3(wpCe.pos),
            normal = wpCe.normal and vec3(wpCe.normal) or nil,
            location = ceLoc and {
              distanceAlongRoute = ceLoc.distanceAlongRoute,
              segmentIndex = ceLoc.segmentIndex,
              xnorm = ceLoc.xnorm,
              pos = vec3(ceLoc.pos),
            } or nil,
          },
        }
      end
    end
  end

  return snapshot
end

function C:ensureDrivelineEditSnapshot()
  if not self.drivelineEditSnapshot then
    self.drivelineEditSnapshot = self:captureDrivelineEditSnapshot()
  end
  return self.drivelineEditSnapshot
end

function C:replaceSnaproadFromDrivelineV3(drivelineV3, snapshot)
  if not (self.path and drivelineV3) then return false end

  local pointList = drivelineV3:getFinalPointList()
  if not pointList then
    log('E', logTag, 'Failed to create PointList from live driveline edit')
    return false
  end

  local previousSnaproad = self.pacenoteToolsState.snaproad
  self.pacenoteToolsState.snaproad = Snaproad(pointList)
  self.path:setSnaproad(self.pacenoteToolsState.snaproad)
  self:markPacenoteGeometryDirty()
  self:markValidationDirty()
  self.pacenoteToolsState.snaproad:reprojectPacenoteWaypoints(self.path, previousSnaproad, snapshot)
  return true
end

function C:refreshAfterDrivelineReproject()
  if not self.path then return end
  self:remeasureAllPacenotes()
  self:autofillDistanceCalls()
  self.path:refreshAllPacenotes()
  self:markPacenoteGeometryDirty()
  self:markValidationDirty()
  if self.pacenoteToolsState.selected_pn_id then
    self:selectPacenote(self.pacenoteToolsState.selected_pn_id)
  end
end

function C:markLiveDrivelineReprojectDirty()
  self.drivelineLiveReprojectDirty = true
  self.drivelineLiveReprojectAt = os.clock() + drivelineReprojectDebounceSecs
end

function C:applyLiveDrivelineReproject(force)
  if not self:isPacenotesDrivelineEditActive() then return end
  if not force and not self.drivelineLiveReprojectDirty then return end
  if not force and self.drivelineLiveReprojectAt and os.clock() < self.drivelineLiveReprojectAt then return end

  local host = self:ensurePacenotesDrivelineHost()
  if not (host and host.drivelineV3) then return end
  self:ensureDrivelineEditSnapshot()

  if host.drivelineV3.spline and host.drivelineV3.spline.isDirty then
    host.drivelineV3:updateSplineGeometry()
  end
  host.drivelineV3:createDrivelineFromSpline()

  if self:replaceSnaproadFromDrivelineV3(host.drivelineV3, self.drivelineEditSnapshot) then
    self:refreshAfterDrivelineReproject()
  end

  self.drivelineLiveReprojectDirty = false
  self.drivelineLiveReprojectAt = nil
end

function C:onPacenotesDrivelineEditCommitted(host)
  if not host then return end
  self:ensureDrivelineEditSnapshot()
  if host.drivelineV3 and host.drivelineV3.spline and host.drivelineV3.spline.isDirty then
    host.drivelineV3:updateSplineGeometry()
  end
  if host.drivelineV3 then
    host.drivelineV3:createDrivelineFromSpline()
  end
  DrivelineEditSurface.saveFinalDriveline(host)
  self.drivelineLiveReprojectDirty = true
  self:applyLiveDrivelineReproject(true)
end

function C:setPacenotesDrivelineEditActive(active)
  active = active and true or false
  if self.pacenoteToolsState.drivelineEditActive == active then return end

  if active then
    self:selectWaypoint(nil)
    self:selectPacenote(nil)

    local host = self:ensurePacenotesDrivelineHost()
    if not host then return end
    if not self.pacenoteToolsState.snaproad then
      self:loadSnaproad()
    end
    self.drivelineEditSnapshot = self:captureDrivelineEditSnapshot()
    self.drivelineLiveReprojectDirty = false
    self.drivelineLiveReprojectAt = nil
  else
    self.drivelineEditSnapshot = nil
    self.drivelineLiveReprojectDirty = false
    self.drivelineLiveReprojectAt = nil
    self.pacenoteDrivelineInputBlocked = false
  end

  self.pacenoteToolsState.drivelineEditActive = active
end

-- Old snaproad loading methods (deprecated - now using DrivelineV3)
-- function C:_loadSnaproadRoute(recce)
--   local missionId = self.path:getMissionId()
--   local missionDir = self.path:getMissionDir()
--   local missionName = rallyUtil.translatedMissionNameFromId(missionId)
--   local styleData = recce.settings:getCornerCallStyle()
--   log('D', logTag, string.format('_loadSnaproadRoute missionId=%s missionDir=%s missionName=%s', missionId, missionDir, missionName))
--   local rallyManager = RallyManager(missionDir, missionId)
--   if not rallyManager:rebuildAssets() then
--     log('E', logTag, 'RallyManager rebuildAssets failed for snaproad setup')
--     return nil
--   end
--   local driveline = Driveline(missionDir)
--   local snaproadPoints = rallyManager:getSnaproadPointsFromRoute()
--   if not snaproadPoints then
--     log('E', logTag, 'failed to get snaproad points from route')
--     return nil
--   end
--   if not driveline:loadFromRoute(snaproadPoints) then
--     log('E', logTag, 'failed to load driveline for route snaproad')
--     return nil
--   end
--   return Snaproad(driveline, styleData, RallyEnums.drivelineMode.route)
-- end

-- function C:_loadSnaproadRecce(recce)
--   local styleData = recce.settings:getCornerCallStyle()
--   return Snaproad(recce.driveline, styleData)
-- end

-- called by RallyEditor when this tab is selected.
function C:selected()
  if not self.path then return end

  if not self.pacenoteToolsState.mode then
    self:setupEditMode()
  end
  self:refreshPacenotesTab(self.drivelineEditSnapshot, { recordHistory = false })
  if self.pacenoteToolsState.snaproad then
    self.pacenoteToolsState.snaproad:setGlobalOpacity(1.0)
  end
  self:selectPacenote(self.pacenoteToolsState.selected_pn_id)

  editor.editModes.notebookEditMode.auxShortcuts[editor.AuxControl_Ctrl] = "Create new pacenote"
  editor.editModes.notebookEditMode.auxShortcuts[editor.AuxControl_Delete] = "Delete"
  -- force redraw of shortcutLegend window
  extensions.hook("onEditorEditModeChanged", nil, nil)
end

-- called by RallyEditor when this tab is unselected.
function C:unselect()
  if not self.path then return end

  self:stopPreviewAudio()
  self.rallyEditor.setFreeCam()

  editor.editModes.notebookEditMode.auxShortcuts[editor.AuxControl_Ctrl] = nil
  editor.editModes.notebookEditMode.auxShortcuts[editor.AuxControl_Delete] = nil
  -- force redraw of shortcutLegend window
  extensions.hook("onEditorEditModeChanged", nil, nil)
end

function C:setOrbitCameraToSelectedPacenote()
  if self:selectedPacenote() then
    core_camera.setByName(0, "pacenoteOrbit")
    core_camera.setRef(0, self:selectedPacenote():getPosForOrbitCamera())
  end
end

function C:selectPacenote(id)
  if not self.path then return end
  if not self.path.pacenotes then return end
  if id and self:isPacenotesDrivelineEditActive() then return end

  -- deselect waypoint if we are changing pacenotes.
  if self.pacenoteToolsState.selected_pn_id ~= id then
    self.pacenoteToolsState.selected_wp_id = nil
    if self.pacenoteToolsState.snaproad then
      self.pacenoteToolsState.snaproad:clearFilter()
    end
  end

  if not id then -- track the most recent selection
    if self.pacenoteToolsState.selected_pn_id then
      self.pacenoteToolsState.recent_selected_pn_id = self.pacenoteToolsState.selected_pn_id
    end
    self:stopPreviewAudio()
    self.pacenoteToolsState.playbackLastCameraPos = nil
  end

  self.pacenoteToolsState.selected_pn_id = id

  self.path:setAdjacentNotes(self.pacenoteToolsState.selected_pn_id)

  -- select the pacenote
  if id then
    local note = self.path.pacenotes.objects[id]
    -- pacenoteNameText = im.ArrayChar(1024, note.name)
    -- playbackRulesText = im.ArrayChar(1024, note.playback_rules)
    self.pacenoteForm:setPacenote(note)
    if self.pacenoteToolsState.snaproad then
      self.pacenoteToolsState.snaproad:setPartitionToPacenote(note)
    end
    -- Recalculate geopacenotes measurement when pacenote is selected
    self:measureSelectedPacenote()
    -- Update orbit camera if currently active
    if core_camera.getActiveGlobalCameraName() == "pacenoteOrbit" then
      self:setOrbitCameraToSelectedPacenote()
    end
  else
    -- pacenoteNameText = im.ArrayChar(1024, "")
    -- playbackRulesText = im.ArrayChar(1024, "")
    self.pacenoteForm:setPacenote(nil)
    if self.pacenoteToolsState.snaproad then
      self.pacenoteToolsState.snaproad:clearPartition()
    end
    self.rallyEditor.setFreeCam()
  end
end

function C:selectWaypoint(id)
  if not self.path then return end
  if id and self:isPacenotesDrivelineEditActive() then return end

  self.pacenoteToolsState.selected_wp_id = id

  if id then
    local waypoint = self.path:getWaypoint(id)
    if waypoint then
      self:selectPacenote(waypoint.pacenote.id)
      -- waypointNameText = im.ArrayChar(1024, waypoint.name)
      self:updateGizmoTransform(id)
      if self.pacenoteToolsState.snaproad then
        self.pacenoteToolsState.snaproad:setFilter(waypoint)
        self.pacenoteToolsState.snaproad:setPartitionToFilter()
      end
    else
      log('E', logTag, 'expected to find waypoint with id='..id)
      if self.pacenoteToolsState.snaproad then
        self.pacenoteToolsState.snaproad:clearFilter()
        self.pacenoteToolsState.snaproad:setPartitionToPacenote(self:selectedPacenote())
      end
    end
  else -- deselect waypoint
    -- waypointNameText = im.ArrayChar(1024, "")
    -- I think this fixes the bug where you cant click on a pacenote waypoint anymore.
    -- I think that was due to the Gizmo being present but undrawn, and the gizmo's mouseover behavior was superseding our pacenote hover.
    self:resetGizmoTransformToOrigin()

    if self.pacenoteToolsState.snaproad then
      self.pacenoteToolsState.snaproad:clearFilter()
      self.pacenoteToolsState.snaproad:setPartitionToPacenote(self:selectedPacenote())
    end

    -- Update orbit camera if currently active (waypoint deselection might change camera focus)
    if core_camera.getActiveGlobalCameraName() == "pacenoteOrbit" then
      self:setOrbitCameraToSelectedPacenote()
    end
  end
end

function C:deselect()
  if self:cameraPathIsPlaying() then return end

  -- since there are two levels of selection (waypoint+pacenote, pacenote),
  -- you must deselect twice to deselect everything.
  if self:selectedWaypoint() then
    self:selectWaypoint(nil)
  else
    self:selectPacenote(nil)
  end
end

function C:attemptToFixMapEdgeIssue()
  self:resetGizmoTransformToOrigin()
end

function C:resetGizmoTransformToOrigin()
  local rotation = QuatF(0,0,0,1)
  local transform = rotation:getMatrix()
  local pos = {0, 0, -1000} -- stick gizmo far away down the Z axis to hide it.
  transform:setPosition(pos)
  editor.setAxisGizmoTransform(transform)
  worldEditorCppApi.setAxisGizmoSelectedElement(-1)
  -- editor.drawAxisGizmo()
end

function C:updateGizmoTransform(index)
  if not self.rallyEditor.allowGizmo() then return end

  local wp = self.path:getWaypoint(index)
  if not wp then return end

  local rotation = QuatF(0,0,0,1)

  if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local then
    local q = quatFromDir(wp.normal, vec3(0,0,1))
    rotation = QuatF(q.x, q.y, q.z, q.w)
  else
    rotation = QuatF(0, 0, 0, 1)
  end

  local transform = rotation:getMatrix()
  transform:setPosition(wp.pos)
  editor.setAxisGizmoTransform(transform)
end

function C:beginDrag()
  if not self:selectedPacenote() then return end
  local wp = self:selectedPacenote().pacenoteWaypoints.objects[self.pacenoteToolsState.selected_wp_id]
  if not wp or wp.missing then return end

  self.beginDragNoteData = wp:onSerialize()

  if wp.normal then
    self.beginDragRotation = deepcopy(quatFromDir(wp.normal, vec3(0,0,1)))
  end

  self.beginDragRadius = wp.radius
end

function C:dragging()
  if not self:selectedPacenote() then return end
  local wp = self:selectedPacenote().pacenoteWaypoints.objects[self.pacenoteToolsState.selected_wp_id]
  if not wp or wp.missing then return end

  -- update/save our gizmo matrix
  if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
    wp:setPos(vec3(editor.getAxisGizmoTransform():getColumn(3)))
  elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Rotate then
    local gizmoTransform = editor.getAxisGizmoTransform()
    local rotation = QuatF(0,0,0,1)
    if wp.normal then
      rotation:setFromMatrix(gizmoTransform)
      if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local then
        wp.normal = quat(rotation)*vec3(0,1,0)
      else
        wp.normal = self.beginDragRotation * quat(rotation)*vec3(0,1,0)
      end
    end
  elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Scale then
    local scl = vec3(worldEditorCppApi.getAxisGizmoScale())
    if scl.x ~= 1 then
      scl = scl.x
    elseif scl.y ~= 1 then
      scl = scl.y
    elseif scl.z ~= 1 then
      scl = scl.z
    else
      scl = 1
    end
    if scl < 0 then
      scl = 0
    end
    wp.radius = self.beginDragRadius * scl
  end
end

function C:endDragging()
  if not self:selectedPacenote() then return end
  local wp = self:selectedPacenote().pacenoteWaypoints.objects[self.pacenoteToolsState.selected_wp_id]
  if not wp or wp.missing then return end

  editor.history:commitAction("Manipulated Note Waypoint via Gizmo",
    {old = self.beginDragNoteData,
     new = wp:onSerialize(),
     index = self.pacenoteToolsState.selected_wp_id, self = self},
    function(data) -- undo
      local wp = self:selectedPacenote().pacenoteWaypoints.objects[data.index]
      wp:onDeserialized(data.old)
      data.self:selectWaypoint(data.index)
    end,
    function(data) --redo
      local wp = self:selectedPacenote().pacenoteWaypoints.objects[data.index]
      wp:onDeserialized(data.new)
      data.self:selectWaypoint(data.index)
    end
  )
end

local function drawLabelRaycastCursor(pos, globalOpacity)
  if not pos then return end
  debugDrawer:drawSphere(pos, 0.9, ColorF(1, 1, 1, 0.85 * (globalOpacity or 1)), false, false)
end

local function drawEmptyNotebookCreateHint(pos, globalOpacity)
  if not pos then return end

  local clr_txt = cc.clr_black
  local clr_bg = cc.clr_green
  debugDrawer:drawTextAdvanced(
    pos,
    String(emptyNotebookCreateHint),
    ColorF(clr_txt[1], clr_txt[2], clr_txt[3], 1 * (globalOpacity or 1)),
    true,
    false,
    ColorI(clr_bg[1] * 255, clr_bg[2] * 255, clr_bg[3] * 255, 255),
    false,
    false
  )
end

local clr_trafficZonePreview = ColorF(0.1, 0.75, 1, 0.18)
local clr_trafficZonePreviewCenter = ColorF(0, 0.95, 1, 0.9)

local function isNavgraphRoadTypeVisualizationEnabled()
  return editor and editor.getVisualizationType and editor.getVisualizationType("drawNavGraphtype")
end

local function drawTrafficExclusionPreviewAtSelectedNode(host)
  if not isNavgraphRoadTypeVisualizationEnabled() then return end
  if not (host and host.drivelineV3 and host.drivelineV3.spline and host.selectedNodeIdx) then return end

  local radius = TrafficExclusion.getDefaultRadius()
  local node = host.drivelineV3.spline.nodes[host.selectedNodeIdx]
  if not node then return end

  debugDrawer:drawSphere(node, radius, clr_trafficZonePreview)
  debugDrawer:drawSphere(node, 0.5, clr_trafficZonePreviewCenter)
end

function C:drawCustomAudioAnchorPickOverlay(globalOpacity)
  local pick = self.customAudioAnchorPick
  if not (pick and pick.basename and self.path and self.path.pacenotes) then return end

  local anchor = self.path:customAudioAnchorInfoFor(pick.basename)
  local currentAnchorPacenoteId = anchor and anchor.pacenote and anchor.pacenote.id or nil
  for _, pacenote in ipairs(self.path.pacenotes.sorted) do
    if pacenote and not pacenote.missing then
      local waypoint = pacenote:getCornerStartWaypoint()
      if waypoint then
        local canAnchor, reason = self.path:canSetCustomAudioAnchor(pacenote, pick.basename)
        local hover = pick.hover_wp_id and pick.hover_wp_id == waypoint.id
        local currentAnchor = currentAnchorPacenoteId and currentAnchorPacenoteId == pacenote.id

        local clr = canAnchor and cc.clr_blue_light or cc.clr_orange
        local alphaShape = canAnchor and 0.72 or 0.36
        local text = nil
        local textFg = cc.clr_white
        local textBg = canAnchor and cc.clr_black or cc.clr_red_dark

        if currentAnchor then
          clr = cc.clr_light_green
          alphaShape = 0.82
          text = hover and "Current anchor pacenote" or "Current anchor"
          textFg = cc.clr_black
          textBg = cc.clr_light_green
        elseif hover then
          text = canAnchor and ("Anchor to "..(pacenote.name or "pacenote")) or (reason or "Cannot anchor here")
        elseif pick.blockedPacenoteId and pick.blockedPacenoteId == pacenote.id and pick.blockedReason then
          text = pick.blockedReason
        end

        waypoint:drawDebug(
          hover,
          text,
          clr,
          alphaShape * (globalOpacity or 1),
          1.0,
          textFg,
          textBg,
          nil,
          globalOpacity
        )
      end
    end
  end
end

function C:drawDebugEntrypoint(globalOpacity, dt)
  -- Accumulate pulse time for waypoint pulsating effect
  if dt then
    self.pacenoteToolsState.pulseTime = self.pacenoteToolsState.pulseTime + dt
  end

  local pacenotesToolsExpanded = self.rallyEditor.isPacenotesToolsSectionExpanded()
  local partitionAllEnabled = self.pacenoteToolsState.snaproad and self.pacenoteToolsState.snaproad:partitionAllEnabled()
  local snaproadPrismWidth = self.rallyEditor.getPrefDrivelineSplinePrismWidth and self.rallyEditor.getPrefDrivelineSplinePrismWidth()
  local snaproadPathOnTop = self.rallyEditor.getViewSnaproadPathOnTop and self.rallyEditor.getViewSnaproadPathOnTop()
  local pacenoteLabelMode = self.rallyEditor.getPrefPacenoteLabelMode and self.rallyEditor.getPrefPacenoteLabelMode()
  local pacenoteLabelDistance = self.rallyEditor.getPrefPacenoteLabelDistance and self.rallyEditor.getPrefPacenoteLabelDistance()
  local pacenoteLabelNearCameraCount = self.rallyEditor.getPrefPacenoteLabelNearCameraCount and self.rallyEditor.getPrefPacenoteLabelNearCameraCount()
  local noSelectionPreviewDrawn = false
  local noPacenoteSelected = not self.pacenoteToolsState.selected_pn_id
  local emptyNotebook = self.path and self.path.pacenotes and #self.path.pacenotes.sorted == 0
  self.pacenoteToolsState._pacenoteLabelRaycastCursorPos = nil

  if self.path and self.pacenoteToolsState.snaproad and not pacenotesToolsExpanded and not partitionAllEnabled and noPacenoteSelected then
    noSelectionPreviewDrawn = NoSelectionPreview.draw(
      self.path,
      self.pacenoteToolsState.snaproad,
      self.pacenoteToolsState,
      globalOpacity,
      snaproadPrismWidth,
      snaproadPathOnTop,
      {
        overviewDistance = pacenoteLabelDistance,
        nearCameraCount = pacenoteLabelNearCameraCount,
        labelMode = pacenoteLabelMode,
      }
    )
  end

  if self.path and self.pacenoteToolsState.snaproad then
    if not pacenotesToolsExpanded and not partitionAllEnabled then
      if not noPacenoteSelected then
        self.path:drawDebugNotebook(self.pacenoteToolsState, globalOpacity)
      end
    end
  end

  if self.pacenoteToolsState.snaproad then
    self.pacenoteToolsState.snaproad:setGlobalOpacity(globalOpacity)
    if not pacenotesToolsExpanded then
      if not noPacenoteSelected then
        self.pacenoteToolsState.snaproad:drawDebugSnaproad(nil, snaproadPrismWidth, snaproadPathOnTop)
      end
    end

    if not noPacenoteSelected and not pacenotesToolsExpanded and not partitionAllEnabled then
      local ghostPath = self.rallyEditor.getGhostNotebookPath and self.rallyEditor.getGhostNotebookPath()
      if ghostPath and self.ghostNotebookRenderer then
        self.ghostNotebookRenderer:draw(ghostPath, self.pacenoteToolsState.snaproad, globalOpacity, self.pacenoteToolsState, self.path)
      end
      drawLabelRaycastCursor(self.pacenoteToolsState._pacenoteLabelRaycastCursorPos, globalOpacity)
    elseif noSelectionPreviewDrawn and not pacenotesToolsExpanded and not partitionAllEnabled then
      drawLabelRaycastCursor(self.pacenoteToolsState._pacenoteLabelRaycastCursorPos, globalOpacity)
      if emptyNotebook and noPacenoteSelected then
        drawEmptyNotebookCreateHint(self.pacenoteToolsState._pacenoteLabelRaycastCursorPos, globalOpacity)
      end
    end

    if not pacenotesToolsExpanded and partitionAllEnabled then
      local ctrlWindow = nil
      if editor.keyModifiers.ctrl and noPacenoteSelected then
        ctrlWindow = NoSelectionPreview.nearWindow(
          self.path,
          self.pacenoteToolsState.snaproad,
          self.pacenoteToolsState,
          { overviewDistance = pacenoteLabelDistance }
        )
      end
      if ctrlWindow then
        self.pacenoteToolsState.snaproad:drawDebugPartitionsAllWindow(ctrlWindow, snaproadPrismWidth, snaproadPathOnTop)
      else
        self.pacenoteToolsState.snaproad:drawDebugSnaproad(nil, snaproadPrismWidth, snaproadPathOnTop)
      end
      self.path:drawDebugNotebookForPartitionAllSnaproad(self.pacenoteToolsState, globalOpacity, ctrlWindow)
    end
  end

  if self:isCustomAudioAnchorPickActive() and self.pacenoteToolsState.snaproad then
    self.pacenoteToolsState.snaproad:drawDebugSnaproad(nil, snaproadPrismWidth, snaproadPathOnTop)
    self:drawCustomAudioAnchorPickOverlay(globalOpacity)
  end

  if self.pacenoteToolsState.playbackLastCameraPos then
    local clr = cc.clr_blue
    local radius = cc.cam_last_pos_radius
    local alpha = cc.cam_last_pos_alpha
    debugDrawer:drawSphere(self.pacenoteToolsState.playbackLastCameraPos, radius, ColorF(clr[1],clr[2],clr[3],alpha))
  end

  self:drawPacenotesDrivelineEditSurface()
end

function C:drawPacenotesDrivelineEditSurface()
  if not self:isPacenotesDrivelineEditActive() then return end

  local host = self:ensurePacenotesDrivelineHost()
  if not (host and host.drivelineV3 and host.drivelineV3.spline) then return end

  local surfaceOpts = {
    inputBlocked = self.pacenoteDrivelineInputBlocked,
    onBeforeMutation = function()
      self:ensureDrivelineEditSnapshot()
    end,
    onSplineMutated = function()
      self:markLiveDrivelineReprojectDirty()
    end,
    onCommit = function(h)
      self:onPacenotesDrivelineEditCommitted(h)
    end,
    onHistoryRestore = function(h)
      self:onPacenotesDrivelineEditCommitted(h)
    end,
  }

  DrivelineEditSurface.handleSplineInteraction(host, surfaceOpts)
  DrivelineEditSurface.refreshSplineGeometry(host, surfaceOpts)

  if host.drivelineV3.spline.divPoints and #host.drivelineV3.spline.divPoints > 0 then
    local splinePrismWidth = self.rallyEditor.getPrefDrivelineSplinePrismWidth and self.rallyEditor.getPrefDrivelineSplinePrismWidth()
    host.drivelineV3:renderSmoothCurve(splinePrismWidth)
  end
  host.drivelineV3:renderSpline(host.selectedNodeIdx)
  drawTrafficExclusionPreviewAtSelectedNode(host)

  self:applyLiveDrivelineReproject(false)
end

function C:drawDebugCameraPlaying()
  if self.pacenoteToolsState.snaproad then
    self.pacenoteToolsState.snaproad:drawDebugCameraPlaying()
  end
end

function C:handleMouseDown(hoveredWp)
  local autoCameraFocus = true

  if hoveredWp then
    self.pacenoteWaypointDragActive = true
    local selectedPn = hoveredWp.pacenote
    if self:selectedPacenote() and self:selectedPacenote().id == selectedPn.id then
      -- print('if a pacenote is already selected and the clicked waypoint is in that pacenote.')
      self.simpleDragMouseOffset = self.mouseInfo._downPos - hoveredWp.pos
      self.beginSimpleDragNoteData = hoveredWp:onSerialize()

      -- if self:selectedWaypoint() then
      if self:selectedWaypoint() and self:selectedWaypoint().id ~= hoveredWp.id then
        if editor.keyModifiers.shift then
          self:setOrbitCameraToSelectedPacenote()
        else
          -- self.pacenote_tools_state.internalLock = true
          self:selectWaypoint(hoveredWp.id)
        end
      elseif self:selectedWaypoint() and self:selectedWaypoint().id == hoveredWp.id then
        -- Same waypoint clicked - only handle shift for camera lock
        if editor.keyModifiers.shift then
          self:setOrbitCameraToSelectedPacenote()
        end
      elseif not self:selectedWaypoint() then
        if editor.keyModifiers.shift then
          -- self.pacenote_tools_state.internalLock = true
          self:setOrbitCameraToSelectedPacenote()
        else
          -- self.pacenote_tools_state.internalLock = true
          self:selectWaypoint(hoveredWp.id)
        end
      end
    elseif self:selectedPacenote() and self:selectedWaypoint() and self:selectedPacenote().id ~= selectedPn.id then
      -- print('if the selected waypoint is from a different pacenote than the clicked waypoint')
      -- Block dragging until mouse up - camera will move in orbit mode
      self.pacenoteToolsState.internalLock = true
      if editor.keyModifiers.shift then
        self:selectPacenote(selectedPn.id)
        self:selectWaypoint(nil)
      else
        self:selectPacenote(selectedPn.id)
        self:selectWaypoint(hoveredWp.id)
      end
    elseif self:selectedPacenote() and self:selectedPacenote().id ~= selectedPn.id then
      -- print('if the selected pacenote is different than clicked waypoint')
      -- Block dragging until mouse up - camera will move in orbit mode
      self.pacenoteToolsState.internalLock = true
      self:selectPacenote(selectedPn.id)
      self:selectWaypoint(nil)
    elseif not self:selectedPacenote() then
      -- print('if no pacenote is selected')
      self:selectPacenote(selectedPn.id)
      self:selectWaypoint(nil)
      if editor.keyModifiers.shift then
        self:setOrbitCameraToSelectedPacenote()
      end
    end
  else
    -- clear selection by clicking off waypoint.
    self:deselect()
  end

  -- if autoCameraFocus then
  --   self:setOrbitCameraToSelectedPacenote()
  -- end
end

function C:onPacenoteDrag(pn_sel)
  self.path:setAdjacentNotes(pn_sel.id)

  -- Recalculate halfpoint during drag
  if self.pacenoteToolsState.snaproad and pn_sel.halfpoint then
    self.pacenoteToolsState.snaproad:updateHalfpoint(pn_sel)
  end

  -- Invalidate camera position cache since waypoints changed
  pn_sel:invalidateCamPosCache()

  self:autofillDistanceCalls()
  self:measureSelectedPacenote(true)

  local pn_prev = pn_sel.prevNote
  if pn_prev then
    pn_prev:refreshStructured()
  end

  pn_sel:refreshStructured()

  local pn_next = pn_sel.nextNote
  if pn_next then
    pn_next:refreshStructured()
  end
end

function C:handleMouseHold()
  local mouse_pos = self.mouseInfo._holdPos

  -- this sphere indicates the drag cursor
  -- debugDrawer:drawSphere((mouse_pos), 1, ColorF(1,1,0,1.0)) -- radius=1, color=yellow

  local wp_sel = self:selectedWaypoint()
  local pn_sel = self:selectedPacenote()

  if wp_sel and not wp_sel:isLocked() and not self.pacenoteToolsState.internalLock then
    if self.mouseInfo.rayCast then
      local new_pos, normal_align_pos = self:wpPosForSimpleDrag(wp_sel, mouse_pos, self.simpleDragMouseOffset)
      local pointsEqual = new_pos and rallyUtil.arePointsEqualWithinThreshold(wp_sel.pos, new_pos, 0.01)
      if new_pos and not pointsEqual then
        local pn_sel = self:selectedPacenote()
        pn_sel:clearTodo()

        wp_sel:setPos(new_pos)
        self:onPacenoteDrag(pn_sel)

        if normal_align_pos and not rallyUtil.arePointsEqualWithinThreshold(new_pos, normal_align_pos, 0.001) then
          local rv = rallyUtil.calculateForwardNormal(new_pos, normal_align_pos)
          wp_sel.normal = vec3(rv.x, rv.y, rv.z)
        end
      end
    end
  end
end

function C:handleMouseUp()
  self.pacenoteToolsState.internalLock = false

  local wp_sel = self:selectedWaypoint()
  local didManipulateWaypoint = false
  if wp_sel and not wp_sel.missing then
    didManipulateWaypoint = true
    editor.history:commitAction("Manipulated Note Waypoint via SimpleDrag",
      {
        self = self, -- the rallyEditor pacenotes tab
        pacenote_idx = self.pacenoteToolsState.selected_pn_id,
        wp_id = self.pacenoteToolsState.selected_wp_id,
        old = self.beginSimpleDragNoteData,
        new = wp_sel:onSerialize(),
        wasPWselection = self.wasWPSelected,
      },
      function(data) -- undo
        local notebook = data.self.path
        local pacenote = notebook.pacenotes.objects[data.pacenote_idx]
        local wp = pacenote.pacenoteWaypoints.objects[data.wp_id]
        wp:onDeserialized(data.old)
        data.self:selectWaypoint(data.wp_id)
        data.self:markPacenoteGeometryDirty()
        data.self:markValidationDirty()
      end,
      function(data) --redo
        local notebook = data.self.path
        local pacenote = notebook.pacenotes.objects[data.pacenote_idx]
        local wp = pacenote.pacenoteWaypoints.objects[data.wp_id]
        wp:onDeserialized(data.new)
        data.self:selectWaypoint(data.wp_id)
        data.self:markPacenoteGeometryDirty()
        data.self:markValidationDirty()
      end
    )
  end
  self.pacenoteWaypointDragActive = false
  if didManipulateWaypoint then
    self:markPacenoteGeometryDirty()
    self:markValidationDirty()
  end
end

function C:setHover(wp)
  self.pacenoteToolsState.hover_wp_id = nil
  self.pacenoteToolsState.shift = false

  if wp then
    self.pacenoteToolsState.hover_wp_id = wp.id

    if editor.keyModifiers.shift then
      self.pacenoteToolsState.shift = true
      if not self:selectedPacenote() or not self:selectedWaypoint() then
        local pos_rayCast = wp.pos
        local clr_txt = cc.clr_black
        local clr_bg = cc.clr_white
        -- debugDrawer:drawTextAdvanced(
        --   pos_rayCast,
        --   String("Lock Camera"),
        --   ColorF(clr_txt[1],clr_txt[2],clr_txt[3],1),
        --   true,
        --   false,
        --   ColorI(clr_bg[1]*255, clr_bg[2]*255, clr_bg[3]*255, 255)
        -- )
      end
    end
  end
end

function C:handleUnmodifiedMouseInteraction(hoveredWp)
  if self.mouseInfo.down then
    self:handleMouseDown(hoveredWp)
  elseif self.mouseInfo.hold then
    self:handleMouseHold()
  elseif self.mouseInfo.up then
    self:handleMouseUp()
  else
    self:setHover(hoveredWp)
  end
end

function C:handleMouseInput()
  if not self.mouseInfo.valid then return end

  -- handle positioning and drawing of the gizmo
  -- if self.pacenote_tools_state.drag_mode == dragModes.gizmo then
  --   self:updateGizmoTransform(self.pacenote_tools_state.selected_wp_id)
  --   editor.drawAxisGizmo()
  -- else
  --   self:resetGizmoTransformToOrigin()
  -- end
  self:resetGizmoTransformToOrigin()
  editor.updateAxisGizmo(function() self:beginDrag() end, function() self:endDragging() end, function() self:dragging() end)

  self.pacenoteToolsState.hover_wp_id = nil -- clear hover state
  if self:isCustomAudioAnchorPickActive() then
    self:handleCustomAudioAnchorPickMouseInput()
    return
  end

  -- There is a bug (in race tool as well) where if you start the game, open
  -- the world editor, and try to use the tool without having selected anything
  -- in Object Select mode (named "Manipulate Object(s)"), then the below line
  -- (which I copied from race tool) will cause the tool not to respond to
  -- mouse interactions.
  --
  -- The Line (which I have commented):
  -- if editor.isAxisGizmoHovered() then return end
  --
  -- Here's the underlying call that editor.isAxisGizmoHovered() uses from gizmo.lua:
  --
  --     -- Return true if the axis gizmo has any hovered elements (axes).
  --     local function isAxisGizmoHovered()
  --       return worldEditorCppApi.getAxisGizmoSelectedElement() ~= -1
  --     end
  --
  -- Turns out that worldEditorCppApi.getAxisGizmoSelectedElement() returns 6
  -- after a cold world editor start. Well, since I'm not using the gizmo for
  -- this tool, I'm just going to comment it and hope for the best.

  local drivelineDragging = self.pacenotesDrivelineHost
    and self.pacenotesDrivelineHost.dragState
    and self.pacenotesDrivelineHost.dragState.isDragging
  local drivelineEditActive = self:isPacenotesDrivelineEditActive()
  local ctrlCreateActive = editor.keyModifiers.ctrl and not self:selectedPacenote()
  local hoveredWp = ctrlCreateActive and nil or self:detectMouseHoverWaypoint()
  local waypointOwnsInput = hoveredWp ~= nil or self.pacenoteWaypointDragActive
  if drivelineEditActive or drivelineDragging then
    waypointOwnsInput = false
  end
  self.pacenoteDrivelineInputBlocked = drivelineEditActive and waypointOwnsInput

  if drivelineEditActive then
    self:setHover(nil)
    return
  elseif ctrlCreateActive then
    self:createMouseDragPacenote()
  elseif self.pacenoteToolsState.snaproad and self.pacenoteToolsState.snaproad:driveline() then
    if self.pacenoteToolsState.snaproad:partitionAllEnabled() then
      self.pacenoteToolsState.snaproad:clearAll()
    end
    self:handleUnmodifiedMouseInteraction(hoveredWp)
  end
end

function C:draw(mouseInfo, dtReal, dtSim, dtRaw)
  self.mouseInfo = mouseInfo
  self:updatePreviewAudio(dtReal, dtSim, dtRaw)

  if self.rallyEditor.allowGizmo() then
    self:handleMouseInput()
  end

  self:drawPacenotesList()
  if self.rallyEditor.getPrefShowSelectedPacenoteUtility and self.rallyEditor.getPrefShowSelectedPacenoteUtility() then
    SelectedPacenoteUtility.draw(self)
  end
end

function C:debugDrawNewPacenote(pos_cs, pos_ce)
  local defaultRadius = self.rallyEditor.getPrefDefaultRadius()
  local radius = defaultRadius

  local alpha = cc.new_pacenote_cursor_alpha
  local clr_link = cc.new_pacenote_cursor_clr_link
  local clr_cs = cc.new_pacenote_cursor_clr_cs
  local clr_ce = cc.new_pacenote_cursor_clr_ce
  debugDrawer:drawSphere((pos_cs), radius, ColorF(clr_cs[1],clr_cs[2],clr_cs[3],alpha))
  debugDrawer:drawSphere((pos_ce), radius, ColorF(clr_ce[1],clr_ce[2],clr_ce[3],alpha))

  local fromHeight = radius * cc.new_pacenote_cursor_linkHeightRadiusShinkFactor
  local toHeight = radius * cc.new_pacenote_cursor_linkHeightRadiusShinkFactor
  debugDrawer:drawSquarePrism(
    pos_cs,
    pos_ce,
    Point2F(fromHeight, cc.new_pacenote_cursor_linkFromWidth),
    Point2F(toHeight, cc.new_pacenote_cursor_linkToWidth),
    ColorF(clr_link[1],clr_link[2],clr_link[3],alpha)
  )
end

function C:debugDrawNewPacenote2(pos_cs, pos_ce)
  local defaultRadius = self.rallyEditor.getPrefDefaultRadius()
  local radius = defaultRadius

  local alpha = cc.new_pacenote_cursor_alpha
  local clr_link = cc.new_pacenote_cursor_clr_link
  local clr_cs = cc.new_pacenote_cursor_clr_cs
  local clr_ce = cc.new_pacenote_cursor_clr_ce
  debugDrawer:drawSphere(pos_cs, radius, ColorF(clr_cs[1],clr_cs[2],clr_cs[3],alpha))
  debugDrawer:drawSphere(pos_ce, radius, ColorF(clr_ce[1],clr_ce[2],clr_ce[3],alpha))

  local fromHeight = radius * cc.new_pacenote_cursor_linkHeightRadiusShinkFactor
  local toHeight = radius * cc.new_pacenote_cursor_linkHeightRadiusShinkFactor
  debugDrawer:drawSquarePrism(
    pos_cs,
    pos_ce,
    Point2F(fromHeight, cc.new_pacenote_cursor_linkFromWidth),
    Point2F(toHeight, cc.new_pacenote_cursor_linkToWidth),
    ColorF(clr_link[1],clr_link[2],clr_link[3],alpha)
  )
end

function C:createMouseDragPacenote()
  if not self.path then return end
  if not self.mouseInfo.rayCast then return end
  if not self.pacenoteToolsState.snaproad then return end

  if not self.pacenoteToolsState.snaproad:partitionAllEnabled() then
    self.pacenoteToolsState.snaproad:partitionAllPacenotes(self.path)
    self.pacenoteToolsState.snaproad:setFilterToAllPartitions()
  end
  local txt = "Click to Create New Pacenote"

  local pos_rayCast = self.mouseInfo.rayCast.pos
  local hoverLoc = self.pacenoteToolsState.snaproad:closestSnapResult(pos_rayCast, true)
  if not partitionForCreateLocation(self.pacenoteToolsState.snaproad, hoverLoc) then
    hoverLoc = nil
  end
  if hoverLoc then
    pos_rayCast = hoverLoc.pos
  end

  -- local pos_ce = self.mouseInfo._holdPos
  -- if pos_ce then
  --   pos_ce = self.pacenote_tools_state.snaproad:closestSnapPos(pos_ce)
  -- end

  if hoverLoc then
    -- draw the cursor text
    local clr_txt = cc.clr_black
    local clr_bg = cc.clr_green
    debugDrawer:drawTextAdvanced(
      pos_rayCast,
      String(txt),
      ColorF(clr_txt[1],clr_txt[2],clr_txt[3],1),
      true,
      false,
      ColorI(clr_bg[1]*255, clr_bg[2]*255, clr_bg[3]*255, 255),
      false,
      false
    )
  end

  if self.mouseInfo.down then
    local pos_down = self.mouseInfo._downPos
    if pos_down then
      local csLoc = self.pacenoteToolsState.snaproad:closestSnapResult(pos_down, true)
      local partition, lowerDist, upperDist, minGap = partitionForCreateLocation(self.pacenoteToolsState.snaproad, csLoc)
      if partition then

        local pn = partition.pacenote_after
        local lastPacenote = self.path.pacenotes.sorted[#self.path.pacenotes.sorted]
        local sortOrder = 1
        if lastPacenote and not lastPacenote.missing then
          sortOrder = lastPacenote.sortOrder + 5 -- default to end of pacenotes list
        end
        if pn then
          sortOrder = pn.sortOrder - 0.5 -- go before the partition's pacenote_after
        end

        local csDistMin = lowerDist
        local csDistMax = upperDist - minGap
        if csLoc.distanceAlongRoute < csDistMin or csLoc.distanceAlongRoute > csDistMax then
          log('W', logTag, 'create pacenote click is outside inter-pacenote space')
          return
        end

        local defaultDistMeters = 10
        local ceDist = math.min(csLoc.distanceAlongRoute + defaultDistMeters, upperDist)
        if ceDist - csLoc.distanceAlongRoute < minGap then
          log('W', logTag, 'not enough snaproad space to create pacenote corner end with minimum waypoint spacing')
          return
        end
        local ceLoc = self.pacenoteToolsState.snaproad:positionAtDistanceAlongRoute(ceDist, true)

        local newPacenote = self.path.pacenotes:create(nil, nil)
        newPacenote.structured:setSlotItems({
          ["4"] = { type = 'corner' },
        })
        newPacenote.sortOrder = sortOrder
        local wp_cs = newPacenote.pacenoteWaypoints:create('corner start', csLoc.pos)
        local wp_ce = newPacenote.pacenoteWaypoints:create('corner end', ceLoc and ceLoc.pos or csLoc.pos)

        local normalVec = self.pacenoteToolsState.snaproad:normalForSnapResult(csLoc)
        if normalVec then
          wp_cs:setNormal(normalVec)
        end

        normalVec = self.pacenoteToolsState.snaproad:normalForSnapResult(ceLoc)
        if normalVec then
          wp_ce:setNormal(normalVec)
        end

        self.path.pacenotes:sort()
        self.path:cleanupPacenoteNames()
        self.pacenoteToolsState.snaproad:clearAll()
        self:autofillDistanceCalls()
        self:selectPacenote(newPacenote.id)
        self:markPacenoteGeometryDirty()
        self:markValidationDirty()
      end
    end
  end
end

function C:detectCustomAudioAnchorPickHover()
  if not self.path then return nil end
  if not (self.mouseInfo and self.mouseInfo.camPos and self.mouseInfo.rayDir) then return nil end

  local minNoteDist = math.huge
  local hoverWp = nil
  for _, pacenote in ipairs(self.path.pacenotes.sorted) do
    if pacenote and not pacenote.missing then
      local waypoint = pacenote:getCornerStartWaypoint()
      if waypoint then
        local distNoteToCam = (waypoint.pos - self.mouseInfo.camPos):length()
        local noteRayDistance = (waypoint.pos - self.mouseInfo.camPos):cross(self.mouseInfo.rayDir):length() / self.mouseInfo.rayDir:length()
        if noteRayDistance <= waypoint.radius and distNoteToCam < minNoteDist then
          minNoteDist = distNoteToCam
          hoverWp = waypoint
        end
      end
    end
  end

  return hoverWp
end

function C:handleCustomAudioAnchorPickMouseInput()
  local pick = self.customAudioAnchorPick
  if not (pick and pick.basename) then return false end

  local hoveredWp = self:detectCustomAudioAnchorPickHover()
  pick.hover_wp_id = hoveredWp and hoveredWp.id or nil
  self.pacenoteToolsState.hover_wp_id = pick.hover_wp_id

  if pick.ignoreMouseDown then
    if self.mouseInfo.down or self.mouseInfo.hold then
      return true
    end
    pick.ignoreMouseDown = false
  end

  if self.mouseInfo.down then
    if hoveredWp and hoveredWp.pacenote then
      local canAnchor, reason = self.path:canSetCustomAudioAnchor(hoveredWp.pacenote, pick.basename)
      if canAnchor and self.path:setCustomAudioAnchor(hoveredWp.pacenote, pick.basename) then
        local pacenoteId = hoveredWp.pacenote.id
        self:cancelCustomAudioAnchorPick()
        self:selectPacenote(pacenoteId)
        self:selectWaypoint(nil)
        self:markValidationDirty()
      else
        pick.blockedReason = reason or "This anchor would conflict with the order of another anchor."
        pick.blockedPacenoteId = hoveredWp.pacenote.id
      end
    else
      self:cancelCustomAudioAnchorPick()
    end
  end

  return true
end

-- figures out which pacenote to select with the mouse in the 3D scene.
function C:detectMouseHoverWaypoint()
  if not self.path then return end
  if not self.path.pacenotes then return end

  local min_note_dist = 4294967295
  local hover_wp = nil
  local selected_pacenote_i = -1
  local waypoints = {}
  local radius_factors = {}

  -- figure out which waypoints are available to select.
  for i, pacenote in ipairs(self.path.pacenotes.sorted) do
    -- if a pacenote is selected, then we can only select it's waypoints.
    if self:selectedPacenote() and self:selectedPacenote().id == pacenote.id then
      selected_pacenote_i = i
      for _,waypoint in ipairs(pacenote.pacenoteWaypoints.sorted) do
        if (waypoint:isCs() or waypoint:isCe()) and not waypoint:isLocked() then
          table.insert(waypoints, waypoint)
        end
      end
    elseif not self:selectedPacenote() then
    -- if no waypoint is selected (ie at the PacenoteSelected mode), we can select any corner start.
      local waypoint = pacenote:getCornerStartWaypoint()
      table.insert(waypoints, waypoint)
    elseif not self:selectedWaypoint() then
    -- if no waypoint is selected (ie at the PacenoteSelected mode), we can select any corner start.
      local waypoint = pacenote:getCornerStartWaypoint()
      radius_factors[waypoint.id] = cc.pacenote_adjacent_radius_factor
      table.insert(waypoints, waypoint)
      waypoint = pacenote:getCornerEndWaypoint()
      radius_factors[waypoint.id] = cc.pacenote_adjacent_radius_factor
      table.insert(waypoints, waypoint)
    end
  end

  -- add waypoints from the previous pacenote.
  if editor_rallyEditor.getPrefShowPreviousPacenote() then
    local prev_i = selected_pacenote_i - 1
    if prev_i > 0 and self:selectedWaypoint() then
      local pn_prev = self.path.pacenotes.sorted[prev_i]
      for _,waypoint in ipairs(pn_prev.pacenoteWaypoints.sorted) do
        if not waypoint:isLocked() then
          radius_factors[waypoint.id] = cc.pacenote_adjacent_radius_factor
          table.insert(waypoints, waypoint)
        end
      end
    end
  end

  -- add waypoints from the next pacenote.
  if editor_rallyEditor.getPrefShowNextPacenote() then
    local next_i = selected_pacenote_i + 1
    if next_i <= #self.path.pacenotes.sorted and self:selectedWaypoint() then
      local pn_next = self.path.pacenotes.sorted[next_i]
      for _,waypoint in ipairs(pn_next.pacenoteWaypoints.sorted) do
        if not waypoint:isLocked() then
          radius_factors[waypoint.id] = cc.pacenote_adjacent_radius_factor
          table.insert(waypoints, waypoint)
        end
      end
    end
  end

  -- of the available waypoints, figure out the closest one.
  for _, waypoint in ipairs(waypoints) do
    local distNoteToCam = (waypoint.pos - self.mouseInfo.camPos):length()
    local noteRayDistance = (waypoint.pos - self.mouseInfo.camPos):cross(self.mouseInfo.rayDir):length() / self.mouseInfo.rayDir:length()
    local sphereRadius =  waypoint.radius
    if radius_factors[waypoint.id] then
      sphereRadius = sphereRadius * radius_factors[waypoint.id]
    end
    if noteRayDistance <= sphereRadius then
      if distNoteToCam < min_note_dist then
        min_note_dist = distNoteToCam
        hover_wp = waypoint
      end
    end
  end

  return hover_wp
end

-- returns new position for the drag, and another position for orienting the normal perpendicularly.
function C:wpPosForSimpleDrag(wp, mousePos, mouseOffset)
  if self.pacenoteToolsState.snaproad then
    if self.mouseInfo.rayCast then
      local newPos = zSnap.zSnapWithCurrentMethod(mousePos - mouseOffset)
      local snapResult = self.pacenoteToolsState.snaproad:closestSnapResult(newPos)
      if snapResult and snapResult.toPoint then
        local alignPos = nil
        if snapResult.toPoint and not rallyUtil.arePointsEqualWithinThreshold(snapResult.pos, snapResult.toPoint.pos, 0.001) then
          alignPos = snapResult.toPoint.pos
        elseif snapResult.fromPoint and not rallyUtil.arePointsEqualWithinThreshold(snapResult.pos, snapResult.fromPoint.pos, 0.001) then
          alignPos = snapResult.fromPoint.pos
        end
        return snapResult.pos, alignPos
      else
        return nil, nil
      end
    else
      return nil, nil
    end
  else
    log('W', logTag, 'wpPosForSimpleDrag hit the else when should no hit else')
    return nil, nil
  end
end

-- local function movePacenoteUndo(data)
--   data.self.path.pacenotes:move(data.index, -data.dir)
-- end
-- local function movePacenoteRedo(data)
--   data.self.path.pacenotes:move(data.index,  data.dir)
-- end
-- local function moveWaypointUndo(data)
--   data.self:selectedPacenote().pacenoteWaypoints:move(data.index, -data.dir)
-- end
-- local function moveWaypointRedo(data)
--   data.self:selectedPacenote().pacenoteWaypoints:move(data.index,  data.dir)
-- end

-- local function setPacenoteFieldUndo(data)
--   data.self.path.pacenotes.objects[data.index][data.field] = data.old
--   data.self.path:sortPacenotesByName()
-- end
-- local function setPacenoteFieldRedo(data)
--   data.self.path.pacenotes.objects[data.index][data.field] = data.new
--   data.self.path:sortPacenotesByName()
-- end

-- local function setWaypointFieldUndo(data)
--   data.self:selectedPacenote().pacenoteWaypoints.objects[data.index][data.field] = data.old
--   data.self:updateGizmoTransform(data.index)
-- end
-- local function setWaypointFieldRedo(data)
--   data.self:selectedPacenote().pacenoteWaypoints.objects[data.index][data.field] = data.new
--   data.self:updateGizmoTransform(data.index)
-- end

-- local function setWaypointNormalUndo(data)
--   local wp = data.self:selectedPacenote().pacenoteWaypoints.objects[data.index]
--   if wp then
--     wp:setNormal(data.old)
--   end
--   data.self:updateGizmoTransform(data.index)
-- end
-- local function setWaypointNormalRedo(data)
--   local wp = data.self:selectedPacenote().pacenoteWaypoints.objects[data.index]
--   if wp and not wp.missing then
--     wp:setNormal(data.new)
--   end
--   data.self:updateGizmoTransform(data.index)
-- end

function C:deleteSelected()
  if self:selectedPacenote() then
    self:deleteSelectedPacenote()
  end
end

function C:deleteSelectedPacenote(shouldSelect)
  if not self.path then return end

  shouldSelect = (shouldSelect == nil) and true

  local pn = self:selectedPacenote()
  local toSelect = pn.prevNote
  if not toSelect then
    toSelect = pn.nextNote
  end

  local notebook = self.path
  notebook.pacenotes:remove(self.pacenoteToolsState.selected_pn_id)

  if shouldSelect and toSelect then
    self:selectPacenote(toSelect.id)
  else
    self:selectPacenote(nil)
  end
  self:markPacenoteGeometryDirty()
  self:markValidationDirty()
end

function C:measureSelectedPacenote(applyMeasurements)
  local pn = self:selectedPacenote()
  if not pn then
    return
  end

  -- log('D', logTag, 'measuring pacenote: '..pn.name)

  if self.pacenoteToolsState.snaproad then
    self.pacenoteToolsState.snaproad:measurePartition()
    if applyMeasurements and pn.applyMeasurements and not pn.missing then
      pn:applyMeasurements()
    end
  end
end

function C:remeasureAllPacenotes()
  if not self.path or not self.path.pacenotes then return end
  local snaproad = self.pacenoteToolsState.snaproad
  if not snaproad then return end

  local selectedId = self.pacenoteToolsState.selected_pn_id

  for _, pn in ipairs(self.path.pacenotes.sorted) do
    if not pn.missing then
      snaproad:setPartitionToPacenote(pn)
      snaproad:measurePartition()
      if pn.applyMeasurements then
        pn:applyMeasurements()
      end
    end
  end

  -- restore partition to the originally selected pacenote
  if selectedId then
    local selPn = self.path.pacenotes.objects[selectedId]
    if selPn and not selPn.missing then
      snaproad:setPartitionToPacenote(selPn)
    else
      snaproad:clearPartition()
    end
  else
    snaproad:clearPartition()
  end
end

function C:selectRecentPacenote()
  if not self:selectedPacenote() then
    if self.pacenoteToolsState.recent_selected_pn_id then
      self:selectPacenote(self.pacenoteToolsState.recent_selected_pn_id)
      return true
    end
  end
  return false
end

function C:selectPrevPacenote()
  if not self.path then return end
  if self:cameraPathIsPlaying() then return end

  if self:selectRecentPacenote() then return end

  local curr = self.path.pacenotes.objects[self.pacenoteToolsState.selected_pn_id]
  local sorted = self.path.pacenotes.sorted

  if curr and not curr.missing then
    local prev = nil
    for i = curr.sortOrder-1,1,-1 do
      local pacenote = sorted[i]
      if self:searchPacenoteMatchFn(pacenote) then
        prev = pacenote
        break
      end
    end

    -- wrap around: find the first usable one
    -- if not prev then
    --   for i = #sorted,1,-1 do
    --     local pacenote = sorted[i]
    --     if self:searchPacenoteMatchFn(pacenote) then
    --       prev = pacenote
    --       break
    --     end
    --   end
    -- end

    if prev then
      self:selectPacenote(prev.id)
    end
  else
    -- if no curr, that means no pacenote was selected, so then select the last one.
    for i = 1,#sorted do
      local pacenote = sorted[i]
      if self:searchPacenoteMatchFn(pacenote) then
        self:selectPacenote(pacenote.id)
        break
      end
    end
  end
end

function C:selectNextPacenote()
  if not self.path then return end
  if self:cameraPathIsPlaying() then return end

  if self:selectRecentPacenote() then return end

  local curr = self.path.pacenotes.objects[self.pacenoteToolsState.selected_pn_id]
  local sorted = self.path.pacenotes.sorted

  if curr and not curr.missing then
    local next = nil
    for i = curr.sortOrder+1,#sorted do
      local pacenote = sorted[i]
      if self:searchPacenoteMatchFn(pacenote) then
        next = pacenote
        break
      end
    end

    -- wrap around: find the first usable one
    -- if not next then
    --   for i = 1,#sorted do
    --     local pacenote = sorted[i]
    --     if self:searchPacenoteMatchFn(pacenote) then
    --       next = pacenote
    --       break
    --     end
    --   end
    -- end

    if next then
      self:selectPacenote(next.id)
    end
  else
    -- if no curr, that means no pacenote was selected, so then select the last one.
    for i = #sorted,1,-1 do
      local pacenote = sorted[i]
      if self:searchPacenoteMatchFn(pacenote) then
        self:selectPacenote(pacenote.id)
        break
      end
    end
  end
end

function C:refreshPacenotesTab(snapshot, opts)
  self:loadSnaproad(snapshot)
  if self.path and self.path.invalidateCustomAudioMapping then
    self.path:invalidateCustomAudioMapping()
  end
  self:remeasureAllPacenotes()
  self:refreshPacenotes(opts)
  self:markPacenoteGeometryDirty()
  self:markValidationDirty()
end

function C:insertMode()
  if self:cameraPathIsPlaying() then return end
  self.pacenoteToolsState.insertMode = true
end

function C:markValidationDirty()
  self.validationDirty = true
end

function C:ensureValidationFresh()
  if not self.validationDirty then return end
  if not (self.path and self.path.pacenotes) then return end
  self:validate()
end

function C:validate()
  if not (self.path and self.path.pacenotes) then return end

  self.validation_issues = {}
  self.notes_valid = true
  self.invalid_notes_count = 0
  self.todo_count = 0
  local notebook_issues = {}

  for _,note in ipairs(self.path.pacenotes.sorted) do
    if note.todo then
      self.todo_count = self.todo_count + 1
    end
    note:validate()
  end

  local invalid_notes_count = 0
  for _,note in ipairs(self.path.pacenotes.sorted) do
    if not note:is_valid() then
      invalid_notes_count = invalid_notes_count + 1
    end
  end

  if invalid_notes_count > 0 then
    self.notes_valid = false
    self.invalid_notes_count = invalid_notes_count
    table.insert(self.validation_issues, tostring(invalid_notes_count)..' pacenote(s) have issues')
  end

  for _, issue in ipairs(notebook_issues) do
    table.insert(self.validation_issues, issue)
  end

  self.validationDirty = false
end

function C:deleteAllPacenotes()
  if not self.path then return end
  self.path:deleteAllPacenotes()
  self:selectPacenote(nil)
  self:markPacenoteGeometryDirty()
  self:markValidationDirty()
  -- self.pacenote_tools_state.snaproad:clearFilter()
  -- self.pacenote_tools_state.snaproad:clearPartition()
end

function C:drawDrivelineEditToggle()
  local active = self:isPacenotesDrivelineEditActive()
  local buttonLabel = active and "Edit Driveline: ON" or "Edit Driveline"

  if active then
    im.PushStyleColor2(im.Col_Button, im.ImVec4(0.9, 0.45, 0.05, 0.85))
    im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(1.0, 0.55, 0.1, 1.0))
    im.PushStyleColor2(im.Col_ButtonActive, im.ImVec4(0.75, 0.35, 0.0, 1.0))
  end

  if im.Button(buttonLabel) then
    self:setPacenotesDrivelineEditActive(not active)
  end

  if active then
    im.PopStyleColor(3)
  end

  im.tooltip("Toggle additive driveline spline editing in the Pacenotes tab.")
end

local function pacenoteTooltipText(path, note)
  local tooltipText = ''
  if note:isAudioModeCustom() then
    local customPreviewText = note:noteOutputCustom() or note:getCustomAudioFile() or ''
    if customPreviewText ~= '' then
      customPreviewText = "  " .. customPreviewText
    end

    local struc = note:noteOutputStructuredOnline()
    if customPreviewText == '' and #struc > 0 then
      customPreviewText = "  " .. dumps(struc)
    end

    tooltipText = customPreviewText
  elseif path:useStructured() then
    tooltipText = dumps(note:noteOutputStructuredOnline())
  else
    tooltipText = note:getNoteFieldFreeform()
  end
  if note:slowCornerAsText() ~= '' then
    tooltipText = tooltipText..'\n'..note:slowCornerAsText()
  end
  return tooltipText
end

local function drawPacenoteListTooltip(path, note, hasIssues, todoTextColor)
  if not im.IsItemHovered() then return end

  local statusText = nil
  local statusColor = nil
  if hasIssues then
    local issueCount = #note.validation_issues
    statusText = issueCount == 1 and "Found one issue" or ("Found " .. tostring(issueCount) .. " issues")
    statusColor = cc.clr_error
  elseif note.todo then
    statusText = "Marked TODO"
    statusColor = todoTextColor
  end

  local tooltipText = pacenoteTooltipText(path, note)
  im.BeginTooltip()
  if statusText then
    im.TextColored(statusColor, statusText)
  end
  if hasIssues and note.todo then
    im.TextColored(todoTextColor, "Marked TODO")
  end
  if tooltipText ~= '' then
    im.TextUnformatted(tooltipText)
  end
  im.EndTooltip()
end

function C:drawPacenotesList()
  if not self.path then return end

  local notebook = self.path
  local notes = notebook.pacenotes.sorted
  self:ensureValidationFresh()

  im.HeaderText(tostring(#notes).." Pacenotes")

  self:drawDrivelineEditToggle()

  im.SameLine()

  im.SetNextItemWidth(80)
  if im.BeginCombo("##pacenotesTodoMenu", "TODO") then
    if im.Selectable1("Mark All TODO") then
      self.path:markAllTodo()
      self:markValidationDirty()
    end
    if im.Selectable1("Mark Rest TODO from Selected") then
      self.path:markRestTodo(self:selectedPacenote())
      self:markValidationDirty()
    end
    if im.Selectable1("Mark All Done") then
      self.path:clearAllTodo()
      self:markValidationDirty()
    end
    im.EndCombo()
  end
  im.tooltip("TODO marking actions for pacenotes.")

  im.SameLine()
  im.SetNextItemWidth(80)
  if im.BeginCombo("##pacenotesActionsMenu", "Actions") then
    if im.Selectable1("Refresh") then
      self:refreshPacenotesTab(self.drivelineEditSnapshot)
    end
    im.tooltip(
      "Reload the snaproad, then for every pacenote:\n"
      .."  - Re-run the geometry measurements for all measurement types.\n"
      .."  - Refresh projected structured/freeform note text.\n"
      .."Then clean up pacenote names and autofill distance calls."
    )
    if im.Selectable1("Delete All...") then
      self.deleteAllPopup = true
    end
    if im.Selectable1("Select Closest to Vehicle") then
      local playerVehicle = getPlayerVehicle(0)
      if playerVehicle then
        local pacenotes = self.path:findNClosestPacenotes(playerVehicle:getPosition(), 1)
        if pacenotes and pacenotes[1] then
          self:selectPacenote(pacenotes[1].id)
        end
      end
    end
    if im.Selectable1("Clear All AudioMode Overrides") then
      self.path:clearPacenoteAudioModeOverrides()
      self:markValidationDirty()
    end
    im.EndCombo()
  end
  im.tooltip("Bulk actions for this notebook.")

  if self:isPacenotesDrivelineEditActive() then
    im.SameLine()
    im.TextColored(im.ImVec4(1.0, 0.55, 0.05, 1.0), "driveline editing active!")
  end

  if self.deleteAllPopup then
    im.OpenPopup("Delete All")
    self.deleteAllPopup = nil
  end

  if im.BeginPopupModal("Delete All", nil, im.WindowFlags_AlwaysAutoResize) then
    im.Text("Delete all pacenotes?")
    im.Separator()
    if im.Button("Ok", im.ImVec2(120,0)) then
      self:deleteAllPacenotes()
      im.CloseCurrentPopup()
    end
    im.SameLine()
    if im.Button("Cancel", im.ImVec2(120,0)) then
      im.CloseCurrentPopup()
    end
    im.EndPopup()
  end

  im.Spacing()
  im.Columns(2)


  -- im.HeaderText("Search")

  -- local editEnded = im.BoolPtr(false)

  -- -- im.SetNextItemWidth(200)
  -- editor.uiInputText("##SearchPn", pacenotesSearchText, nil, nil, nil, nil, editEnded)
  -- if editEnded[0] then
  --   self.pacenoteToolsState.search = ffi.string(pacenotesSearchText)

  --   if rallyUtil.trimString(self.pacenoteToolsState.search) == '' then
  --     self.pacenoteToolsState.search = nil
  --   end

  --   if self.pacenoteToolsState.search then
  --     log('D', logTag, 'searching pacenotes: '..self.pacenoteToolsState.search)
  --     local pn = self:selectedPacenote()
  --     if pn then
  --       if not self:pacenoteSearchMatches(pn) then
  --         self:selectNextPacenote()
  --         local pn2 = self:selectedPacenote()
  --         if pn2 and pn.id == pn2.id then
  --           self:selectPrevPacenote()
  --         end
  --       end
  --     end
  --   end
  -- end
  -- im.SameLine()
  -- if im.Button("X") then
  --   self.pacenoteToolsState.search = nil
  --   pacenotesSearchText = im.ArrayChar(1024, "")
  -- end

  -- if im.Button("Prev") then
  --     self:selectPrevPacenote()
  -- end
  -- im.SameLine()
  -- if im.Button("Next") then
  --     self:selectNextPacenote()
  -- end

  local todoTextColor = im.ImVec4(1.0, 0.45, 0.05, 1.0)
  local todoHeading = self.todo_count > 0 and ("TODO: " .. tostring(self.todo_count)) or "No TODO"
  if self:isValid() then
    im.TextColored(cc.clr_no_error, "No issues")
    im.SameLine()
    im.TextColored(todoTextColor, todoHeading)
  else
    local issuesHeading = self.invalid_notes_count and self.invalid_notes_count > 0
      and ("Issues: " .. tostring(self.invalid_notes_count))
      or ("Issues (".. (#self.validation_issues) ..")")
    im.TextColored(cc.clr_error, issuesHeading)
    im.SameLine()
    im.TextColored(todoTextColor, todoHeading)
  end
  if #notes == 0 then
    im.TextColored(im.ImVec4(0.2, 1.0, 0.2, 1.0), emptyNotebookCreateHint)
  end

  -- im.HeaderText("Selected Pacenote")
  -- im.BeginChild1("pacenotes", im.ImVec2(270*im.uiscale[0], 0), im.WindowFlags_ChildWindow)
  im.BeginChild1("pacenotes", nil, im.WindowFlags_ChildWindow)
  -- im.BeginChild1("pacenotes", nil, im.WindowFlags_ChildWindow)
  im.ImGuiListClipper_Begin(pacenotesListClipper, #notes)
  while im.ImGuiListClipper_Step(pacenotesListClipper) do
    for row = pacenotesListClipper.DisplayStart + 1, pacenotesListClipper.DisplayEnd do
      local note = notes[row]
      if note then
        local pushedTextColor = false
        local hasIssues = not note:is_valid()
        if hasIssues then
          im.PushStyleColor2(im.Col_Text, cc.clr_error)
          pushedTextColor = true
        elseif note.todo then
          im.PushStyleColor2(im.Col_Text, todoTextColor)
          pushedTextColor = true
        end
        local isSelected = note.id == self.pacenoteToolsState.selected_pn_id
        if isSelected then
          im.PushStyleColor2(im.Col_Header, im.ImVec4(0.45, 1.0, 0.55, 0.34))
          im.PushStyleColor2(im.Col_HeaderHovered, im.ImVec4(0.45, 1.0, 0.55, 0.42))
          im.PushStyleColor2(im.Col_HeaderActive, im.ImVec4(0.45, 1.0, 0.55, 0.50))
        end
        if im.Selectable1(note:pacenoteTextForSelect(), isSelected) then
          self:selectPacenote(note.id)
          -- Enable orbit camera when clicking on a pacenote
          self:setOrbitCameraToSelectedPacenote()
        end
        if isSelected then
          im.PopStyleColor(3)
        end
        if pushedTextColor then
          im.PopStyleColor()
        end

        drawPacenoteListTooltip(self.path, note, hasIssues, todoTextColor)
      end
    end
  end
  im.EndChild() -- pacenotes child window
  im.SameLine()

  im.NextColumn()

  local pacenote = self.path.pacenotes.objects[self.pacenoteToolsState.selected_pn_id]
  if im.BeginTabBar("pacenoteDetailTabs") then
    if im.BeginTabItem("Pacenote") then
      self.pacenoteForm:draw()
      im.EndTabItem()
    end
    if self.path:isAudioModeCustom() then
      if im.BeginTabItem("Audio") then
        CustomAudioList.draw(self.path, (pacenote and not pacenote.missing) and pacenote or nil, self)
        im.EndTabItem()
      end
    end
    im.EndTabBar()
  end

  im.Columns(1)
end

function C:searchPacenoteMatchFn(pacenote)
  return pacenote and not pacenote.missing and self:pacenoteSearchMatches(pacenote)
end

function C:pacenoteSearchMatches(pacenote)
  if not self.pacenoteToolsState.search then return true end

  local searchPattern = rallyUtil.trimString(self.pacenoteToolsState.search)
  if searchPattern == '' then return true end

  return pacenote:matchesSearchPattern(searchPattern)
end

-- function C:handleNoteFieldEdit(note, language, subfield, buf)
--   local newVal = note.notes
--   local lang_data = newVal[language] or {}
--   local val = rallyUtil.trimString(ffi.string(buf))

--   if subfield == 'note' then
--     local last = note.id == self.path.pacenotes.sorted[#self.path.pacenotes.sorted].id
--     val = note:normalizeNoteText(language, last, false, val)
--     val = { freeform = val }
--   end

--   lang_data[subfield] = val
--   newVal[language] = lang_data

--   -- editor.history:commitAction("Change Notes of Pacenote",
--   --   {
--   --     index = self.pacenoteToolsState.selected_pn_id,
--   --     self = self,
--   --     old = note.notes,
--   --     new = newVal,
--   --     field = 'notes'
--   --   },
--   --   setPacenoteFieldUndo,
--   --   setPacenoteFieldRedo
--   -- )

--   -- self.path.pacenotes.objects[self.pacenoteToolsState.selected_pn_id].notes = newVal
--   self:selectedPacenote().notes = newVal
-- end

function C:cleanupPacenoteNames(recordHistory)
  if not self.path then return end

  if recordHistory == false then
    self.path:cleanupPacenoteNames()
    return
  end

  editor.history:commitAction("Cleanup pacenote names",
    {
      self = self,
      notebook = self.path,
      old_pacenotes = deepcopy(self.path.pacenotes:onSerialize()),
    },
    function(data) -- undo
      data.notebook.pacenotes:onDeserialized(data.old_pacenotes, {})
    end,
    function(data) -- redo
      data.self:selectPacenote(nil)
      data.notebook:cleanupPacenoteNames()
    end
  )
end

function C:autofillDistanceCalls()
  if not self.path then return end
  -- log('D', logTag, 'autofilling distance calls')
  self.path:autofillDistanceCalls()
  self:markValidationDirty()
end

function C:refreshPacenotes(opts)
  if not self.path then return end
  opts = opts or {}

  self:cleanupPacenoteNames(opts.recordHistory)
  self.path:refreshPacenotes({ cleanupNames = false, remeasure = false })
  self:markPacenoteGeometryDirty()
  self:markValidationDirty()
end

function C:placeVehicleAtPacenote()
  local pos, rot = self:selectedPacenote():vehiclePlacementPosAndRot()

  if pos and rot then
    local playerVehicle = getPlayerVehicle(0)
    if playerVehicle then
      spawn.safeTeleport(playerVehicle, pos, rot)
    end
  end
end

function C:insertNewPacenoteAfter(note)
  if not self.path then return end

  local pn_next = nil

  for i,pn in ipairs(self.path.pacenotes.sorted) do
    if pn.id == note.id then
      pn_next = i+1
    end
  end

  local _, numA = note:nameComponents()
  numA = tonumber(numA)
  local nextNum = numA

  if pn_next <= #self.path.pacenotes.sorted then
    local next_note = self.path.pacenotes.sorted[pn_next]
    if next_note then
      local _, numB = next_note:nameComponents()
      numB = tonumber(numB)
      nextNum = numA + ((numB - numA) / 2)
    end
  else
    nextNum = numA+1
  end

  -- local currId = self:selectedPacenote().id
  -- num = tonumber(num) + 0.01

  local newPacenote = self.path.pacenotes:create("Pacenote "..tostring(nextNum))
  self.path:sortPacenotesByName()
  self:markPacenoteGeometryDirty()
  self:markValidationDirty()
  -- self:cleanupPacenoteNames()
  -- self:selectPacenote(currId)
end

function C:selectNextWaypoint()
  if self:cameraPathIsPlaying() then return end

  -- if there's no selected PN, select the recent one.

  -- if not pn then
  --   if self.pacenote_tools_state.recent_selected_pn_id then
  --     self:selectPacenote(self.pacenote_tools_state.recent_selected_pn_id)
  --   end
  --   return
  -- end

  -- if self:selectRecentPacenote() then return end
  self:selectRecentPacenote()

  local pn = self:selectedPacenote()
  if not pn then return end

  local wp_sel = self:selectedWaypoint()

  if wp_sel then
    local wp_new = nil
    if wp_sel:isCs() then
      wp_new = pn:getCornerEndWaypoint()
    elseif wp_sel:isCe() then
      wp_new = pn:getCornerStartWaypoint()
    end
    if wp_new and not wp_new:isLocked() then
      self:selectWaypoint(wp_new.id)
    end
  else
    local wp = nil
    wp = pn:getCornerStartWaypoint()
    self:selectWaypoint(wp.id)
  end
end

function C:_moveSelectedWaypointHelper(fwd, steps)
  local wp = self:selectedWaypoint()
  if not wp then
    self:selectNextWaypoint()
    wp = self:selectedWaypoint()
    return
  end

  if self.pacenoteToolsState.snaproad then
    local pn = self:selectedPacenote()
    pn:clearTodo()
    pn:moveWaypointTowards(self.pacenoteToolsState.snaproad, wp, fwd, steps)
    self:markPacenoteGeometryDirty()
    self:markValidationDirty()
  end
end

function C:moveSelectedWaypointForward(steps)
  if self:cameraPathIsPlaying() then return end
  steps = steps or 1
  self:_moveSelectedWaypointHelper(true, steps)
end

function C:moveSelectedWaypointBackward(steps)
  if self:cameraPathIsPlaying() then return end
  steps = steps or 1
  self:_moveSelectedWaypointHelper(false, steps)
end

function C:cameraPathPlay()
  if not self.pacenoteToolsState.snaproad then
    log('W', logTag, 'cameraPathPlay: no snaproad available')
    return
  end

  local pacenote = self:selectedPacenote()
  if not pacenote then
    log('W', logTag, 'cameraPathPlay: no pacenote selected')
    return
  end

  if self:cameraPathIsPlaying() then
    -- Stop playback
    self.pacenoteToolsState.snaproad:stopCameraPath()
    self:stopPreviewAudio()
    self.pacenoteToolsState.playbackLastCameraPos = core_camera.getPosition()
    if self.pacenoteToolsState.last_camera.name == "pacenoteOrbit" then
      self:setOrbitCameraToSelectedPacenote()
    else
      core_camera.setPosition(0, self.pacenoteToolsState.last_camera.pos)
      core_camera.setRotation(0, self.pacenoteToolsState.last_camera.quat)
    end
    self:selectPacenote(pacenote.id)
    log('I', logTag, 'Camera path playback stopped')
  else
    -- Start playback
    self:selectWaypoint(nil)
    self.pacenoteToolsState.last_camera.pos = core_camera.getPosition()
    self.pacenoteToolsState.last_camera.quat = core_camera.getQuat()
    self.pacenoteToolsState.last_camera.name = core_camera.getActiveGlobalCameraName()
    self.pacenoteToolsState.snaproad:playCameraPath()
    self:startPreviewAudio(pacenote)
    log('I', logTag, 'Camera path playback started')
  end
end

function C:cameraPathIsPlaying()
  return core_camera.getActiveCamName() == "path"
end

function C:toggleCornerCalls()
  log('D', logTag, 'toggleCornerCalls will be implemented in the future')
  -- local snaproadType = editor.getPreference("rallyEditor.editing.preferredSnaproadType")
  -- if snaproadType == 'route' then
    -- TODO corner calls not supported for route yet.
    -- return
  -- end

  -- if self.pacenoteToolsState.snaproad then
    -- self.pacenoteToolsState.snaproad:toggleCornerCalls()
  -- end
end

function C:setModeEditAll()
  self.pacenoteToolsState.mode = editModes.editAll
  editor_rallyEditor.setPrefLockWaypoints(false)
end

function C:setModeEditCorners()
  self.pacenoteToolsState.mode = editModes.editCorners
  editor_rallyEditor.setPrefLockWaypoints(false)
end

function C:setupEditMode()
  self:selectWaypoint(nil)
  self:setModeEditCorners()

  if self.pacenoteToolsState.snaproad and self:selectedPacenote() then
    self.pacenoteToolsState.snaproad:setPartitionToPacenote(self:selectedPacenote())
  end
end

function C:mergeSelectedWithPrevPacenote()
  local pn = self:selectedPacenote()
  if not pn then return end

  local pnPrev = pn.prevNote
  if not pnPrev then return end

  local currText = pn:getNoteFieldFreeform()
  local prevText = pnPrev:getNoteFieldFreeform()
  local mergedText = prevText..' '..currText

  pnPrev:setNoteFieldFreeform(mergedText)
  self:deleteSelectedPacenote(false)

  self:selectPacenote(pnPrev.id)
  self:markPacenoteGeometryDirty()
  self:markValidationDirty()
end

function C:mergeSelectedWithNextPacenote()
  local pn = self:selectedPacenote()
  if not pn then return end

  local pnNext = pn.nextNote
  if not pnNext then return end

  local currText = pn:getNoteFieldFreeform()
  local nextText = pnNext:getNoteFieldFreeform()
  local mergedText = currText..' '..nextText

  pnNext:setNoteFieldFreeform(mergedText)
  self:deleteSelectedPacenote(false)

  self:selectPacenote(pnNext.id)
  self:markPacenoteGeometryDirty()
  self:markValidationDirty()
end

function C:generateElevationProfile()
  if not self.path then
    log('E', logTag, 'generateElevationProfile: no path available')
    return nil
  end

  local missionId = self.path:getMissionId()
  local missionDir = self.path:getMissionDir()

  log('D', logTag, string.format('generateElevationProfile missionId=%s missionDir=%s', missionId, missionDir))

  -- Create a RallyManager to access the drivelineRoute
  local rallyManager = RallyManager(missionDir, missionId)

  if not rallyManager:rebuildAssets() then
    log('E', logTag, 'RallyManager rebuildAssets failed for elevation profile generation')
    return nil
  end

  -- Get the drivelineRoute which contains buildElevationProfile
  local drivelineRoute = rallyManager.drivelineRoute
  if not drivelineRoute then
    log('E', logTag, 'no drivelineRoute available for elevation profile generation')
    return nil
  end

  if not drivelineRoute.buildElevationProfile then
    log('E', logTag, 'buildElevationProfile method not available on drivelineRoute')
    return nil
  end

  -- Call buildElevationProfile and return the result
  local elevationProfile = drivelineRoute:buildElevationProfile()

  if elevationProfile and #elevationProfile > 0 then
    log('I', logTag, string.format('generated elevation profile with %d points', #elevationProfile))
  else
    log('W', logTag, 'elevation profile generation returned empty or nil result')
  end

  return elevationProfile
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
