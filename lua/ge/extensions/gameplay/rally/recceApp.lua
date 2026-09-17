-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local cc = require('/lua/ge/extensions/gameplay/rally/util/colors')
local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
-- local Recce = require('/lua/ge/extensions/gameplay/rally/recce')
local RecceSettings = require('/lua/ge/extensions/gameplay/rally/recceSettings')
local VehicleCapture = require('/lua/ge/extensions/gameplay/rally/vehicleCapture')
local CutCapture = require('/lua/ge/extensions/gameplay/rally/cutCapture')
local kdTreeP3d = require('kdtreepoint3d')

local logTag = ''

local M = {}

local enabled = false
-- loaded extension state
local recceSettings = nil
local cornerStartsKdTree = nil
local cornerStartsIndex = nil
local showNotes = true

-- mission list state
local missionList = nil
local lastMissionId = nil
local lastLoadState = nil
local cornerAnglesStyle = nil
local recceWindowOpen = im.BoolPtr(false)
local recceWindowSelectedMissionId = nil
local recceWindowMessage = nil
local recceWindowLastLoadSuccess = true
local showShortDriveline = false

-- recording state
local vehicleCapture = nil
local cutCapture = nil
-- recording settings state
local _isRecordingDriveline = false
local shouldRecordDriveline = false
local shouldRecordVoice = false

local function getPlayerVehicleForRecce()
  return getPlayerVehicle(0)
end

local function getRallyManager()
  return gameplay_rally.getRallyManager()
end

local function isFreeroam()
  return core_gamestate.state and core_gamestate.state.state == "freeroam"
end

local function canManageMission()
  if not gameplay_rally or not gameplay_rally.canManageMission then
    return false, 'rally extension is unavailable'
  end
  return gameplay_rally.canManageMission('recce')
end

local function ensureRecceDirs()
  if not getRallyManager() then return end

  local missionDir = getRallyManager():getMissionDir()
  local dirname = rallyUtil.missionRecceRecordDir(missionDir)

  if not FS:directoryExists(dirname) then
    log('D', logTag, 'creating recce dirs: '..dirname)
    FS:directoryCreate(dirname, true)
  end
end

local function setEnabled(val)
  enabled = val
end

local function isEnabled()
  return enabled
end

local function initCaptures()
  if not getRallyManager() then return end

  log('D', logTag, 'initCaptures')

  vehicleCapture = nil
  cutCapture = nil
  local missionDir = getRallyManager():getMissionDir()

  if isFreeroam() and missionDir then
    local veh = getPlayerVehicleForRecce()
    ensureRecceDirs()
    vehicleCapture = VehicleCapture(veh, missionDir)
    cutCapture = CutCapture(veh, missionDir)
  end
end

local function setLastMissionId(mid)
  if recceSettings then
    recceSettings:setLastMissionId(getCurrentLevelIdentifier(), mid)
  end
end

local function setLastLoadState(state)
  if recceSettings then
    recceSettings:setLastLoadState(getCurrentLevelIdentifier(), state)
  end
end

local function loadMission(missionId, missionDir)
  -- log('D', logTag, 'loadMission')

  local loaded, loadError = gameplay_rally.loadMission(missionId, missionDir, nil, nil, {owner = 'recce'})
  if not loaded then
    log('W', logTag, 'loadMission rejected: '..tostring(loadError))
    guihooks.trigger('rally.recceApp.missionLoaded', false, loadError)
    return false, loadError
  end

  local rm = gameplay_rally.getRallyManager()
  if not rm then
    log('E', logTag, 'loadMission failed, no rally manager')
    local errorMsgForUser = gameplay_rally.getErrorMsgForUser()
    guihooks.trigger('rally.recceApp.missionLoaded', false, errorMsgForUser)
    return false, errorMsgForUser
  end

  cornerStartsKdTree = nil
  cornerStartsIndex = nil

  local notebook = rm and rm:getNotebookPath() or nil
  if notebook and notebook.pacenotes and notebook.pacenotes.sorted then
    cornerStartsIndex = {}
    for _, pacenote in ipairs(notebook.pacenotes.sorted) do
      local wp = pacenote:getCornerStartWaypoint()
      if wp and wp.pos then
        cornerStartsIndex[wp:nameWithPacenote()] = wp
        table.insert(cornerStartsIndex, wp)
      end
    end

    if #cornerStartsIndex > 0 then
      cornerStartsKdTree = kdTreeP3d.new(#cornerStartsIndex)
      for _, wp in ipairs(cornerStartsIndex) do
        cornerStartsKdTree:preLoad(wp:nameWithPacenote(), wp.pos.x, wp.pos.y, wp.pos.z)
      end

      cornerStartsKdTree:build()
    else
      cornerStartsIndex = nil
    end

    -- if gameplay_rally.getRallyToolbox() then
    --   gameplay_rally.getRallyToolbox():setDrivelineMode(rm:getDrivelineMode())
    -- end
  end

  setLastMissionId(missionId)
  setLastLoadState(true)
  guihooks.trigger('rally.recceApp.missionLoaded', true, nil)
  return true, nil
end

local function unloadMission()
  -- log('D', logTag, 'unloadMission')
  local unloaded, unloadError = gameplay_rally.unloadMission({owner = 'recce'})
  if not unloaded then
    log('W', logTag, 'unloadMission rejected: '..tostring(unloadError))
    return false, unloadError
  end
  setLastLoadState(false)
  return true
end

local function release()
  enabled = false
  recceWindowOpen[0] = false
  vehicleCapture = nil
  cutCapture = nil
  if gameplay_rally and gameplay_rally.getRallyManagerOwner and gameplay_rally.getRallyManagerOwner() == 'recce' then
    gameplay_rally.unloadMission({owner = 'recce'})
  end
end

local function updateVehicleCapture()
  if not vehicleCapture then return end
  if shouldRecordDriveline then
    vehicleCapture:capture()
  end
end

local function draw()
  if showNotes and not (editor and editor.isEditorActive()) then
    local rm = gameplay_rally.getRallyManager()
    if rm and isFreeroam() and not gameplay_rally.isRallyToolboxVisible() then
      rm:drawPacenotesForDriving()
    end
  end

  if showShortDriveline then
    local rm = gameplay_rally.getRallyManager()
    local dr = rm and rm:getDrivelineRoute() or nil
    if dr then
      dr:drawDebugDrivelineRouteShort(100)
    end
  end
end

local function moveVehicleToStart()
  local rm = getRallyManager()
  if not rm then return end

  local racePath = rm:getRacePath()
  local startPosId = racePath.defaultStartPosition
  local startPos = racePath.startPositions.objects[startPosId]

  local playerVehicle = getPlayerVehicleForRecce()
  if playerVehicle and startPos then
    local pos, rot = startPos:calculateVehiclePosRot(playerVehicle:getID())
    if pos and rot then
      local safeTeleportRot = rot * quat(0, 0, -1, 0)
      spawn.safeTeleport(playerVehicle, pos, safeTeleportRot)
      if not rm:resyncAfterTeleport() then
        log('E', logTag, 'moveVehicleToStart failed, failed to resync rally manager after teleport')
      end
    end
  end
end

local function moveVehicleToPacenoteV2(forward)
  local playerVehicle = getPlayerVehicleForRecce()
  if not playerVehicle then return end
  local rm = getRallyManager()
  if not rm then return end
  if not rm:getNotebookPath() then return end
  if not cornerStartsKdTree or not cornerStartsIndex then return end
  if cornerStartsKdTree and cornerStartsKdTree.itemCount == 0 then return end
  -- if not cornerStartsKdTree then return end

  local vPos = playerVehicle:getPosition()
  local nearestCsName, dist = cornerStartsKdTree:findNearest(vPos.x, vPos.y, vPos.z)
  local wp = cornerStartsIndex[nearestCsName]

  if not wp then
    log('E', logTag, 'moveVehicleToPacenoteV2 failed, no nearest wp found')
    return
  end

  local pacenoteForMove = nil
  local distToMove = 10

  -- log('D', logTag, 'moveVehicleToPacenoteV2: closest pacenote('..wp.pacenote.name..') dist='..dist)

  if dist < distToMove+2 then
    -- since the vehicle is close to a pacenote, let's move to the next or previous pacenote.
    if forward then
      -- log('D', logTag, 'moveVehicleToPacenoteV2: moving to next pacenote')
      pacenoteForMove = wp.pacenote.nextNote
    else
      -- log('D', logTag, 'moveVehicleToPacenoteV2: moving to previous pacenote')
      pacenoteForMove = wp.pacenote.prevNote
    end
  else
    -- log('D', logTag, 'moveVehicleToPacenoteV2: moving to current pacenote')
    -- since the vehicle is not close to a pacenote, let's move to the pacenote.
    pacenoteForMove = wp.pacenote
  end

  if pacenoteForMove then
    -- log('D', logTag, 'moveVehicleToPacenoteV2: moving to pacenote '..pacenoteForMove.name)
    local drivelineRoute = rm:getDrivelineRoute()
    if not drivelineRoute then
      log('E', logTag, 'moveVehicleToPacenoteV2 failed, no driveline route found')
      return
    end

    local pos, rot = drivelineRoute:vehiclePlacementPosAndRotForPacenote(pacenoteForMove, distToMove)
    if not pos or not rot then
      log('E', logTag, 'moveVehicleToPacenoteV2 failed, could not calculate placement pose')
      return
    end

    spawn.safeTeleport(playerVehicle, pos, rot)

    if not rm:resyncAfterTeleport() then
      log('E', logTag, 'moveVehicleToPacenoteV2 failed, failed to resync rally manager after teleport')
      return
    end
  else
    -- log('E', logTag, 'moveVehicleToPacenoteV2 failed, no pacenoteForMove found')
  end
end

local function moveVehicleForward()
  moveVehicleToPacenoteV2(true)
end

local function moveVehicleBackward()
  moveVehicleToPacenoteV2(false)
end

local function moveVehicleToMission()
  local rm = getRallyManager()
  if not rm then return end

  local missionStartTrigger = rm:getMissionStartTrigger()
  if not missionStartTrigger then
    log('E', logTag, 'moveVehicleToMission: mission start trigger not found')
    return
  end

  local pos = missionStartTrigger.pos
  local rot = missionStartTrigger.rot

  local playerVehicle = getPlayerVehicleForRecce()
  if playerVehicle then
    spawn.safeTeleport(playerVehicle, vec3(pos), quat(rot))
    if not rm:resyncAfterTeleport() then
      log('E', logTag, 'moveVehicleToMission failed, failed to resync rally manager after teleport')
    end
  end
end

local drawRecceWindow

local function onUpdate(dtReal, dtSim, dtRaw)
  if not enabled then return end
  profilerPushEvent("RecceApp - onUpdate")

  draw()
  if recceWindowOpen[0] and drawRecceWindow then
    drawRecceWindow()
  end
  updateVehicleCapture()

  profilerPopEvent("RecceApp - onUpdate")
end

local function setShowNotes(val)
  showNotes = val
end

local function setShowShortDriveline(val)
  showShortDriveline = val == true
  local toolbox = gameplay_rally and gameplay_rally.getRallyToolbox and gameplay_rally.getRallyToolbox() or nil
  if toolbox and toolbox.debug then
    toolbox.debug.drawRouteShort = showShortDriveline
  end
end

local function recordDrivelineCut()
  log('I', logTag, 'recordDrivelineCut')

  if cutCapture then
    local cutId = cutCapture:capture()
    if shouldRecordVoice then
      local request = {
        -- vehicle_data = getVehiclePosForCut(),
        cut_id = cutId,
      }
      local resp = extensions.gameplay_rally_client.transcribe_recording_cut(request)
      if not resp.ok then
        guihooks.trigger('rallyInputActionDesktopCallNotOk', resp.client_msg)
      end
    end
  end
end

local function recordDrivelineStart(recordVoice)
  log('I', logTag, 'recordDrivelineStart')

  _isRecordingDriveline = true
  shouldRecordDriveline = true
  shouldRecordVoice = recordVoice

  initCaptures()
end

local function recordDrivelineStop()
  log('I', logTag, 'recordDrivelineStop')

  _isRecordingDriveline = false

  if vehicleCapture and shouldRecordDriveline then
    vehicleCapture:writeCaptures(true)
  end

  vehicleCapture = nil
  cutCapture = nil
  shouldRecordDriveline = false
  shouldRecordVoice = false
end

local function recordDrivelineClearAll()
  _isRecordingDriveline = false
  initCaptures()
  vehicleCapture:truncateCapturesFile()
  cutCapture:truncateCapturesFile()
  cutCapture:truncateTranscriptsFile()

  vehicleCapture = nil
  cutCapture = nil
end

-- local function onVehicleSwitched()
--   log('D', 'rally', 'onVehicleSwitched')
-- end
--
-- local function onVehicleSpawned()
--   log('D', 'rally', 'onVehicleSpawned')
-- end

local function toggleDebug()
  gameplay_rally.toggleDebug()
end

local function missionDisplayName(mission)
  if not mission then return '<none>' end
  return tostring(mission.missionName or mission.missionId or '<unnamed>')..' ['..tostring(mission.missionType or '<unknown>')..']'
end

local function findMissionById(missionId)
  if not missionId then return nil end
  for _, mission in ipairs(missionList or {}) do
    if mission.missionId == missionId then return mission end
  end
  return nil
end

local function currentRallyMissionId()
  local rm = gameplay_rally and gameplay_rally.getRallyManager and gameplay_rally.getRallyManager() or nil
  return rm and rm.getMissionId and rm:getMissionId() or nil
end

local function selectedMission()
  if not missionList or #missionList == 0 then
    recceWindowSelectedMissionId = nil
    return nil
  end

  local mission = findMissionById(recceWindowSelectedMissionId)
    or findMissionById(currentRallyMissionId())
    or findMissionById(lastMissionId)
    or missionList[1]

  recceWindowSelectedMissionId = mission and mission.missionId or nil
  return mission
end

local function refreshMissionState()
  log('I', logTag, 'refreshing recce app missions')
  local level = getCurrentLevelIdentifier()

  local filterFn = function (mission)
    local startTrigger = mission and mission.startTrigger or nil
    return startTrigger and startTrigger.level == level and (mission.missionType == 'rallyStage' or mission.missionType == 'rallyStageLoop' or mission.missionType == 'rallyRoadSection')
  end

  missionList = {}

  for _, mission in ipairs(gameplay_missions_missions.getFilesData() or {}) do
    -- if mission.startTrigger.level == level then
    --   dump(mission.name .. ' ' .. mission.missionType)
    -- end

    if filterFn(mission) then
      local missionData = {
        missionId = mission.id,
        missionDir = mission.missionFolder,
        missionName = rallyUtil.translatedMissionName(mission.name),
        missionType = mission.missionType,
      }
      table.insert(missionList, missionData)
    end
  end
  recceSettings:load()

  if recceSettings then
    lastMissionId = recceSettings:getLastMissionId(level)
    lastLoadState = recceSettings:getLastLoadState(level)
    cornerAnglesStyle = recceSettings:getCornerCallStyle()
  else
    lastMissionId = nil
    lastLoadState = false
    cornerAnglesStyle = nil
  end
end

local function reload(rallyExt)
  if gameplay_rally and gameplay_rally.getDebugLogging() then log('D', logTag, 'reload') end

  recceSettings = RecceSettings()
  recceSettings:load()

  refreshMissionState()

  local resp = {
    missions = missionList,
    last_mission_id = lastMissionId,
    last_load_state = lastLoadState,
    can_auto_load = canManageMission() == true,
    corner_angles_style = cornerAnglesStyle,
  }

  guihooks.trigger('rally.recceApp.refreshed', resp)
end

local function refreshRecceWindow()
  reload()
  selectedMission()
end

local function openWindow()
  setEnabled(true)
  recceWindowOpen[0] = true
  refreshRecceWindow()
end

local function closeWindow()
  recceWindowOpen[0] = false
end

local function toggleWindow()
  if recceWindowOpen[0] then
    closeWindow()
  else
    openWindow()
  end
end

drawRecceWindow = function()
  if not missionList then
    refreshRecceWindow()
  end

  local viewport = im.GetMainViewport()
  local bottomMargin = 24 * (im.uiscale and im.uiscale[0] or 1)
  local pos = im.ImVec2(viewport.Pos.x + viewport.Size.x * 0.5, viewport.Pos.y + viewport.Size.y - bottomMargin)
  im.SetNextWindowPos(pos, im.Cond_Always, im.ImVec2(0.5, 1.0))
  if im.Begin("Recce Toolbox##rallyRecceImgui", recceWindowOpen, im.WindowFlags_AlwaysAutoResize) then
    local mission = selectedMission()
    local rm = gameplay_rally and gameplay_rally.getRallyManager and gameplay_rally.getRallyManager() or nil

    im.SetNextItemWidth(420)
    if im.BeginCombo("##rallyRecceMission", missionDisplayName(mission)) then
      for _, entry in ipairs(missionList or {}) do
        local isSelected = mission and entry.missionId == mission.missionId
        if im.Selectable1(missionDisplayName(entry), isSelected) then
          recceWindowSelectedMissionId = entry.missionId
          recceWindowMessage = nil
        end
        if isSelected then
          im.SetItemDefaultFocus()
        end
      end
      im.EndCombo()
    end
    im.SameLine()
    if im.Button("Refresh##rallyRecceRefreshMissions") then
      recceWindowMessage = nil
      refreshRecceWindow()
    end

    if im.Button("Load##rallyRecceLoadMission") then
      mission = selectedMission()
      if mission then
        recceWindowMessage = "loading mission..."
        local ok, err = loadMission(mission.missionId, mission.missionDir)
        recceWindowLastLoadSuccess = ok == true
        recceWindowMessage = ok and nil or (err or "failed to load mission")
      else
        recceWindowLastLoadSuccess = false
        recceWindowMessage = "select a mission"
      end
    end
    im.SameLine()
    if im.Button("Unload##rallyRecceUnloadMission") then
      unloadMission()
      recceWindowLastLoadSuccess = true
      recceWindowMessage = "mission unloaded"
    end

    rm = gameplay_rally and gameplay_rally.getRallyManager and gameplay_rally.getRallyManager() or nil
    if rm then
      im.SameLine()
      im.Text("loaded: "..tostring(rm:getMissionName()))
    elseif recceWindowMessage then
      im.SameLine()
      local color = recceWindowLastLoadSuccess and im.ImVec4(0.7, 0.9, 0.7, 1) or im.ImVec4(1, 0.35, 0.25, 1)
      im.TextColored(color, recceWindowMessage)
    else
      im.SameLine()
      im.Text("no mission loaded")
    end

    local showNotesPtr = im.BoolPtr(showNotes)
    if im.Checkbox("Next Pacenote##rallyRecceShowNotes", showNotesPtr) then
      setShowNotes(showNotesPtr[0])
    end
    im.SameLine()
    local showDrivelinePtr = im.BoolPtr(showShortDriveline)
    if im.Checkbox("Short Route##rallyRecceShowShortDriveline", showDrivelinePtr) then
      setShowShortDriveline(showDrivelinePtr[0])
    end

    local noMissionLoaded = rm == nil
    if noMissionLoaded then im.BeginDisabled() end
    im.Text("Move Vehicle")
    im.SameLine()
    if im.Button("Forward##rallyRecceMoveVehicleForward") then
      moveVehicleForward()
    end
    im.SameLine()
    if im.Button("Back##rallyRecceMoveVehicleBackward") then
      moveVehicleBackward()
    end
    im.SameLine()
    if im.Button("Start##rallyRecceMoveVehicleToStart") then
      moveVehicleToStart()
    end
    im.SameLine()
    if im.Button("Mission##rallyRecceMoveVehicleToMission") then
      moveVehicleToMission()
    end
    if noMissionLoaded then im.EndDisabled() end
  end
  im.End()
end

local function toggleMouseLikeVehicle()
  -- log('I', logTag, 'toggleMouseLikeVehicle')
  if not gameplay_rally.getRallyToolbox() then return end
  gameplay_rally.getRallyToolbox():toggleMouseMovementCheckbox()
end

-- was considering using this for full-imgui recce app
  -- if im.BeginCombo("Missions", self.selectedMission and self.selectedMission.missionName or "Select Mission") then

  --   for _, mission in ipairs(self.missions or {}) do

  --     local isSelected = self.selectedMission and self.selectedMission.missionID == mission.missionID
  --     if im.Selectable1(mission.missionName, isSelected) then
  --       self.selectedMission = mission
  --     end
  --     if isSelected then
  --       im.SetItemDefaultFocus()
  --     end
  --   end
  --   im.EndCombo()
  -- end

  -- im.SameLine()

  -- if im.Button('Refresh') then
  --   self:refresh()
  -- end

  -- if im.Button('Load Mission') then
  --   self:loadMission()
  -- end
  -- im.SameLine()
  -- if im.Button('Unload Mission') then
  --   self:unloadMission()
  -- end


  -- im.Text("Vehicle Controls")
  -- if im.Button('<-') then
  -- end
  -- im.SameLine()
  -- if im.Button('->') then
  -- end

-- local function getCurrentState()
--   local resp = {
--     missions = self.missions,
--     last_mission_id = self.lastMissionId,
--     last_load_state = self.lastLoadState,
--     corner_angles_style = self.cornerAnglesStyle,
--   }
--   return resp
-- end

-- was considering using this for a full-imgui recce app
-- function C:loadMission()
--   if not self.selectedMission then return end

--   local missionId = self.selectedMission.missionId
--   local missionDir = self.selectedMission.missionDir
--   local missionName = self.selectedMission.missionName


--   -- log('D', 'loadMission: ' .. missionId)

--   self.rallyExt.loadMission(missionId, missionDir, missionName)
--   -- local rallyManager = self.rallyExt.getRallyManager()

--   -- if rallyManager then
--     -- self.missionDir = missionDir
--     -- self.missionId = missionId
--     -- self.missionName = missionName

--     -- local selectedPacenote = rallyManager:closestPacenoteToVehicle()
--     -- if selectedPacenote then
--     --   self.selectedPacenote = selectedPacenote
--     --   log('D', logTag, 'closest pacenote to vehicle: '..selectedPacenote.name)
--     -- end

--     -- if missionDir then
--       -- local recce = Recce(missionDir)
--       -- recce:load()
--       -- self.snaproad = Snaproad(recce)
--     -- end
--   -- end
-- end

-- was considering using this for a full-imgui recce app
-- function C:unloadMission()
--   log('D', 'recceApp.unloadMission')

--   self.rallyExt.unloadMission()

--   -- self.selectedMission = nil
--   -- self.missionDir = nil
--   -- self.missionId = nil
--   -- self.missionName = nil
--   -- self.snaproad = nil
--   -- self.selectedPacenote = nil


--   -- self.rallyExt.clearRallyManager()
-- end

-- function C:translatedMissionName()
--   local rm = gameplay_rally.getRallyManager()
--   if rm then
--     local missionName = rm:translatedMissionName()
--     return missionName
--   else
--     return '<none>'
--   end
-- end


M.onUpdate = onUpdate
M.reload = reload
M.loadMission = loadMission
M.unloadMission = unloadMission
M.release = release
M.setLastMissionId = setLastMissionId
M.setLastLoadState = setLastLoadState
M.setShowNotes = setShowNotes
M.moveVehicleBackward = moveVehicleBackward
M.moveVehicleForward = moveVehicleForward
M.moveVehicleToStart = moveVehicleToStart
M.moveVehicleToMission = moveVehicleToMission
M.recordDrivelineCut = recordDrivelineCut
M.recordDrivelineStart = recordDrivelineStart
M.recordDrivelineStop = recordDrivelineStop
M.recordDrivelineClearAll = recordDrivelineClearAll
M.isRecording = function() return _isRecordingDriveline end
M.setEnabled = setEnabled
M.isEnabled = isEnabled
M.openWindow = openWindow
M.closeWindow = closeWindow
M.toggleWindow = toggleWindow
M.isWindowVisible = function() return recceWindowOpen[0] end
M.toggleDebug = toggleDebug
M.toggleMouseLikeVehicle = toggleMouseLikeVehicle

return M
