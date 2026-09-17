-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local voicepack = require('/lua/ge/extensions/gameplay/rally/voicepack')
local RallyEnums = require('/lua/ge/extensions/gameplay/rally/enums')
local RallyToolbox = require('/lua/ge/extensions/gameplay/rally/tools/rallyToolbox')
local DevTools = require('/lua/ge/extensions/gameplay/rally/tools/devTools')
local RallyManager = require('/lua/ge/extensions/gameplay/rally/rallyManager')
local zSnap = require('/lua/ge/extensions/editor/rallyEditor/zSnap')
local GhostNotebook = require('/lua/ge/extensions/editor/rallyEditor/ghostNotebook')
local CalibrationWindow = require('/lua/ge/extensions/editor/rallyEditor/pacenotes/calibrationWindow')
local StageLoaderModal = require('/lua/ge/extensions/editor/rallyEditor/stageLoaderModal')

local M = {}
M.dependencies = {'gameplay_missions_missions'}
local logTag = ''

local toolWindowName = "rallyEditor"
local editModeName = "Rally Editor"
local focusWindow = false
local mouseInfo = {}

local devToolsWindowOpen = im.BoolPtr(false)
local devTools = nil
local rallyToolboxWindowOpen = im.BoolPtr(false)
local rallyToolbox = nil
local rallyLoopToolboxWindowOpen = im.BoolPtr(false)
local rallyLoopToolbox = nil
local ghostNotebook = nil
local calibrationWindowOpen = im.BoolPtr(false)
local stageLoaderOpen = im.BoolPtr(false)

local currentPath = nil

-- The "designated mission" the editor is currently working in. Set when the user opens the rally
-- editor from the mission editor; the notebook dropdown lists notebooks under this mission.
local currentMissionDir = nil   -- absolute path to the mission folder
local currentMissionName = nil  -- human-readable label for the toolbar
local currentMissionId = nil    -- e.g. "italy/rallyStage/001-ss-fastello-norte"

-- The chosen voicepack pick for this editor session. Drives which notebooks the notebook
-- dropdown lists. Mirrors the toolbox pick shape:
--   { type='voicepack', scope='global',  dirname=<voicepackDir> }
--   { type='voicepack', scope='mission', dirname=<voicepackDir> }
local currentVoicepackPick = nil

local windows = {}
local pacenotesWindow, recceWindow, testWindow, drivelineWindow, aiCompetitorsWindow
local currentWindow = {}
local changedWindow = false
local programmaticTabSelect = false
local isDev = false

local debugDrawOpacity = 1.0
local pacenoteLabelModeAll = "all"
local pacenoteLabelModeDistance = "distance"
local pacenoteLabelModeValues = {pacenoteLabelModeAll, pacenoteLabelModeDistance}
local pacenoteLabelModeLabels = {
  [pacenoteLabelModeAll] = "Show all",
  [pacenoteLabelModeDistance] = "Show near camera",
}
local pacenoteLabelDistanceMin = 100
local pacenoteLabelDistanceMax = 1500
local pacenoteLabelDistanceDefault = 650
local pacenoteLabelNearCameraCountMin = 0
local pacenoteLabelNearCameraCountMax = 10
local pacenoteLabelNearCameraCountDefault = 3
local drivelineSplinePrismWidthMin = 0.5
local drivelineSplinePrismWidthMax = 5.0
local drivelineSplinePrismWidthDefault = 1.945
local hideTheForest = false
local snaproadPathOnTop = false

local function applyTheForestHidden()
  local forest = scenetree.findObject("theForest")
  if forest then
    forest.hidden = hideTheForest
  end
end

local function setHideTheForest(hidden)
  hideTheForest = hidden == true
  applyTheForestHidden()
end

local function resetEphemeralViewOptions()
  setHideTheForest(false)
  snaproadPathOnTop = false
end

local function clampPacenoteLabelDistance(distance)
  distance = tonumber(distance) or pacenoteLabelDistanceDefault
  return math.max(pacenoteLabelDistanceMin, math.min(pacenoteLabelDistanceMax, distance))
end

local function clampPacenoteLabelNearCameraCount(count)
  count = math.floor((tonumber(count) or pacenoteLabelNearCameraCountDefault) + 0.5)
  return math.max(pacenoteLabelNearCameraCountMin, math.min(pacenoteLabelNearCameraCountMax, count))
end

local function clampDrivelineSplinePrismWidth(width)
  width = tonumber(width) or drivelineSplinePrismWidthDefault
  return math.max(drivelineSplinePrismWidthMin, math.min(drivelineSplinePrismWidthMax, width))
end

local function getRawEditorPreference(key)
  if editor and editor.getPreference then
    return editor.getPreference(key)
  end
  return nil
end

local function getPacenoteLabelModePreference()
  local mode = getRawEditorPreference('rallyEditor.view.pacenoteLabelMode')
  local legacyShowAll = getRawEditorPreference('rallyEditor.view.showAllPacenoteLabels') == true

  if legacyShowAll then
    return pacenoteLabelModeAll
  end
  if mode == pacenoteLabelModeAll or mode == pacenoteLabelModeDistance then
    return mode
  end
  return pacenoteLabelModeDistance
end

local function setPacenoteLabelModePreference(mode)
  if not (editor and editor.setPreference) then return end
  if mode ~= pacenoteLabelModeAll then
    mode = pacenoteLabelModeDistance
  end
  editor.setPreference('rallyEditor.view.pacenoteLabelMode', mode)
  editor.setPreference('rallyEditor.view.showAllPacenoteLabels', mode == pacenoteLabelModeAll)
end

local function getPacenoteLabelDistancePreference()
  return clampPacenoteLabelDistance(getRawEditorPreference('rallyEditor.view.pacenoteLabelDistance'))
end

local function setPacenoteLabelDistancePreference(distance)
  if not (editor and editor.setPreference) then return end
  editor.setPreference('rallyEditor.view.pacenoteLabelDistance', clampPacenoteLabelDistance(distance))
end

local function getPacenoteLabelNearCameraCountPreference()
  return clampPacenoteLabelNearCameraCount(getRawEditorPreference('rallyEditor.view.pacenoteLabelNearCameraCount'))
end

local function setPacenoteLabelNearCameraCountPreference(count)
  if not (editor and editor.setPreference) then return end
  editor.setPreference('rallyEditor.view.pacenoteLabelNearCameraCount', clampPacenoteLabelNearCameraCount(count))
end

local function getDrivelineSplinePrismWidthPreference()
  return clampDrivelineSplinePrismWidth(getRawEditorPreference('rallyEditor.view.drivelineSplinePrismWidth'))
end

local function setDrivelineSplinePrismWidthPreference(width)
  if not (editor and editor.setPreference) then return end
  editor.setPreference('rallyEditor.view.drivelineSplinePrismWidth', clampDrivelineSplinePrismWidth(width))
end

local function getShowAdjacentPacenoteTextPreference()
  local value = getRawEditorPreference('rallyEditor.view.showAdjacentPacenoteText')
  if value == nil then return true end
  return value == true
end

local function setShowAdjacentPacenoteTextPreference(show)
  if not (editor and editor.setPreference) then return end
  editor.setPreference('rallyEditor.view.showAdjacentPacenoteText', show == true)
end

local function getShowSelectedPacenoteUtilityPreference()
  local value = getRawEditorPreference('rallyEditor.view.showSelectedPacenoteUtility')
  if value == nil then return false end
  return value == true
end

local function setShowSelectedPacenoteUtilityPreference(show)
  if not (editor and editor.setPreference) then return end
  editor.setPreference('rallyEditor.view.showSelectedPacenoteUtility', show == true)
end

local function viewDefaultButton(id, tooltip)
  im.SameLine()
  local clicked = im.Button("o##"..id, editor.miniIconButtonSize)
  im.tooltip(tooltip or "Reset to default")
  return clicked
end

local function devTxtExists()
  return FS:fileExists('dev.txt')
end

local function select(window)
  if currentWindow.unselect then
    currentWindow:unselect()
  end
  currentWindow = window
  if currentWindow.setPath then
    currentWindow:setPath(currentPath)
  end
  if currentWindow.selected then
    currentWindow:selected()
  end
  changedWindow = true
end

local function saveNotebook()
  if not currentPath then
    log('W', logTag, 'cant save; no notebook loaded.')
    return
  end

  if not currentPath:save() then
    return
  end
end

local function selectPrevPacenote()
  if currentWindow ~= pacenotesWindow then return end
  pacenotesWindow:selectPrevPacenote()
end

local function selectNextPacenote()
  if currentWindow ~= pacenotesWindow then return end
  pacenotesWindow:selectNextPacenote()
end

local function insertMode()
  if currentWindow ~= pacenotesWindow then return end
  pacenotesWindow:insertMode()
end

local function setFreeCam()
  local lastCamPos = core_camera.getPosition()
  local lastCamRot = core_camera.getQuat()

  core_camera.setByName(0, 'free')
  core_camera.setPosition(0, lastCamPos)
  core_camera.setRotation(0, lastCamRot)
end

local function deselect()
  if currentWindow ~= pacenotesWindow then return end
  pacenotesWindow:deselect()
end

local function selectNextWaypoint()
  if currentWindow ~= pacenotesWindow then return end
  pacenotesWindow:selectNextWaypoint()
end

local moveWaypointState = {
  debounce = 0.25,
  lastMoveTs = 0,
  forward = 0,
  backward = 0,
}

local zoomState = {
  debounce = 0.05,
  lastZoomTs = 0,
  zoomIn = 0,
  zoomOut = 0,
}

local function resetInputState()
  moveWaypointState.lastMoveTs = 0
  moveWaypointState.forward = 0
  moveWaypointState.backward = 0

  zoomState.lastZoomTs = 0
  zoomState.zoomIn = 0
  zoomState.zoomOut = 0
end

-- called directly by the input action
local function moveSelectedWaypointForward(v)
  if currentWindow ~= pacenotesWindow then return end

  if v == 0 then
    moveWaypointState.lastMoveTs = 0
  end

  moveWaypointState.forward = v
end
-- called directly by the input action
local function moveSelectedWaypointBackward(v)
  if currentWindow ~= pacenotesWindow then return end

  if v == 0 then
    moveWaypointState.lastMoveTs = 0
  end

  moveWaypointState.backward = v
end

local function cameraPathPlay()
  if currentWindow ~= pacenotesWindow then return end
  pacenotesWindow:cameraPathPlay()
end

local function toggleCornerCalls()
  if currentWindow ~= pacenotesWindow then return end
  pacenotesWindow:toggleCornerCalls()
end

-- local function moveSelectedWaypointForwardFast()
--   pacenotesWindow:moveSelectedWaypointForwardFast()
-- end
--
-- local function moveSelectedWaypointBackwardFast()
--   pacenotesWindow:moveSelectedWaypointBackwardFast()
-- end

local function updateWindowNotebooks()
  for _, window in ipairs(windows) do
    if window.setPath then
      window:setPath(currentPath)
    end
  end
end

local function clearNotebook()
  if currentWindow and currentWindow.unselect then
    currentWindow:unselect()
  end

  if ghostNotebook then
    ghostNotebook:clear()
  end

  currentPath = nil
  currentMissionDir = nil
  currentMissionName = nil
  currentMissionId = nil
  currentVoicepackPick = nil
  focusWindow = false
  changedWindow = false
  programmaticTabSelect = false
  debugDrawOpacity = 1.0
  resetEphemeralViewOptions()
  resetInputState()
  table.clear(mouseInfo)

  devTools = nil
  rallyToolbox = nil
  rallyLoopToolbox = nil

  if editor and editor.clearObjectSelection then
    editor.clearObjectSelection()
  end

  for _, window in ipairs(windows) do
    if window.clearState then
      window:clearState()
    end
  end

  updateWindowNotebooks()
end

local function setCurrentMission(missionDir)
  if ghostNotebook and currentMissionDir ~= missionDir then
    ghostNotebook:clear()
  end

  currentMissionDir = missionDir
  currentMissionId = nil
  currentMissionName = nil

  if not missionDir then return end

  currentMissionId = missionDir:match("/missions/(.+)$")

  local info = jsonReadFile(missionDir..'/info.json')
  if info and info.name then
    currentMissionName = _tr(info.name)
  else
    -- fall back to the last path segment
    currentMissionName = missionDir:match("([^/]+)$") or missionDir
  end
end

local function clearCurrentMission()
  if ghostNotebook then
    ghostNotebook:clear()
  end

  currentMissionDir = nil
  currentMissionName = nil
  currentMissionId = nil
  currentVoicepackPick = nil
end

local function loadOrCreateNotebook(fullFilename)
  local notebook = rallyUtil.loadNotebook(fullFilename)
  if not notebook then
    log('D', logTag, 'couldnt load notebook, so creating a new one: '..fullFilename)
    notebook = rallyUtil.createNotebook(fullFilename)
  end

  currentPath = notebook
  -- local snaproadType = currentPath:getSnaproadType()
  -- editor.setPreference("rallyEditor.editing.preferredSnaproadType", snaproadType)
  updateWindowNotebooks()
  -- structured-note cache derivation needs the editor's voicepack pick, which is
  -- only honoured after currentPath has been set to this notebook.
  notebook:refreshAllStructuredNotes()
end

local function loadNotebook(fullFilename)
  -- if not full_filename then
  --   return
  -- end

  -- local json = jsonReadFile(full_filename)
  -- if not json then
  --   log('E', logTag, 'couldnt find notebook file')
  -- end

  -- local newPath = require('/lua/ge/extensions/gameplay/rally/notebook/path')()
  -- newPath:setFname(full_filename)
  -- newPath:onDeserialized(json)

  local notebook = rallyUtil.loadNotebook(fullFilename)
  if not notebook then
    log('E', logTag, 'couldnt load notebook: '..fullFilename)
    return
  end

  currentPath = notebook
  updateWindowNotebooks()
  -- structured-note cache derivation needs the editor's voicepack pick, which is
  -- only honoured after currentPath has been set to this notebook.
  notebook:refreshAllStructuredNotes()
end

-- Sets the active voicepack pick and auto-loads the first candidate notebook for it.
-- Clears the loaded notebook if the pick has no resolvable candidates.
local function setVoicepackPick(pick)
  currentVoicepackPick = pick
  local basenames = voicepack.notebookBasenamesForPick(currentMissionDir, pick)
  if basenames[1] then
    loadNotebook(rallyUtil.getNotebookFullPath(currentMissionDir, basenames[1]..'.notebook.json'))
  else
    clearNotebook()
  end
end

local function updateMouseInfo()
  if core_forest.getForestObject() then core_forest.getForestObject():disableCollision() end
  mouseInfo.camPos = core_camera.getPosition()
  mouseInfo.ray = getCameraMouseRay()
  mouseInfo.rayDir = vec3(mouseInfo.ray.dir)
  mouseInfo.rayCast = cameraMouseRayCast()
  mouseInfo.valid = mouseInfo.rayCast and true or false

  if core_forest.getForestObject() then core_forest.getForestObject():enableCollision() end
  if not mouseInfo.valid then
    mouseInfo.down = false
    mouseInfo.hold = false
    mouseInfo.up   = false
  else
    mouseInfo.down =  im.IsMouseClicked(0) and not im.GetIO().WantCaptureMouse
    mouseInfo.hold = im.IsMouseDown(0) and not im.GetIO().WantCaptureMouse
    mouseInfo.up =  im.IsMouseReleased(0) and not im.GetIO().WantCaptureMouse
    if mouseInfo.down then
      mouseInfo.hold = false
      mouseInfo._downPos = vec3(mouseInfo.rayCast.pos)
    end
    if mouseInfo.hold then
      mouseInfo._holdPos = vec3(mouseInfo.rayCast.pos)
    end
    if mouseInfo.up then
      mouseInfo._upPos = vec3(mouseInfo.rayCast.pos)
    end
  end
end

local function openMission()
  editor_missionEditor.show()
  local mid = currentPath:getMissionId()
  if mid then
    editor_missionEditor.setMissionById(mid)
  end
end

-- local function setPreferredSnaproadType(snaproadType)
--   editor.setPreference("rallyEditor.editing.preferredSnaproadType", snaproadType)
--   pacenotesWindow:loadSnaproad()
-- end

local function moveWaypointWithDebounce()
  local wp_fwd = moveWaypointState.forward == 1
  local wp_bak = moveWaypointState.backward == 1
  local wpMoveChanged = wp_fwd or wp_bak

  if wpMoveChanged then
    local diff = rallyUtil.getTime() - moveWaypointState.lastMoveTs
    local debounce = moveWaypointState.debounce
    local steps = 1

    if editor.keyModifiers.shift then
      debounce = debounce / 8
    end

    if editor.keyModifiers.ctrl then
      if editor.keyModifiers.shift then
        debounce = debounce * 2
      end
      steps = 10
    end

    if diff > debounce then
      moveWaypointState.lastMoveTs = rallyUtil.getTime()
      if wp_fwd then
        pacenotesWindow:moveSelectedWaypointForward(steps)
      elseif wp_bak then
        pacenotesWindow:moveSelectedWaypointBackward(steps)
      end
    end
  end
end

local function zoomWithDebounce()
  local zoom_in = zoomState.zoomIn == 1
  local zoom_out = zoomState.zoomOut == 1
  local zoomChanged = zoom_in or zoom_out

  if zoomChanged and core_camera and core_camera.getActiveCamName() == 'pacenoteOrbit' then
    local diff = rallyUtil.getTime() - zoomState.lastZoomTs
    local debounce = zoomState.debounce
    local zoomAmount = 0.4

    if editor.keyModifiers.shift then
      debounce = debounce / 4
      zoomAmount = zoomAmount * 2
    end

    if editor.keyModifiers.ctrl then
      if editor.keyModifiers.shift then
        debounce = debounce * 2
      end
      zoomAmount = zoomAmount * 3
    end

    if diff > debounce then
      zoomState.lastZoomTs = rallyUtil.getTime()
      if zoom_in then
        core_camera.cameraZoom(-zoomAmount)
      elseif zoom_out then
        core_camera.cameraZoom(zoomAmount)
      end
    end
  end
end

local function drawDevTools()
  if not devToolsWindowOpen[0] then return end
  if not devTools then
    devTools = DevTools()
  end
  im.Begin("Rally Dev Tools", devToolsWindowOpen)
    devTools:draw()
    devTools:onUpdate() -- Call onUpdate to handle 3D debug drawing
  im.End()
end

local function drawRallyToolbox()
  if not rallyToolboxWindowOpen[0] then return end
  if not rallyToolbox then
    rallyToolbox = RallyToolbox()

    -- Set up RallyManager for rally editor context
    if currentPath then
      local missionId = currentPath:getMissionId()
      local missionDir = currentPath:getMissionDir()

      if missionId and missionDir then
        log('D', logTag, string.format('Setting up RallyManager for toolbox: missionId=%s missionDir=%s', missionId, missionDir))
        local rallyManager = RallyManager(missionDir, missionId)

        if rallyManager:rebuildAssets() then
          rallyToolbox:setRallyManager(rallyManager)
        else
          log('E', logTag, 'RallyManager rebuildAssets failed for rally toolbox setup')
        end
      else
        log('W', logTag, 'Could not set up RallyManager for toolbox: missing mission info')
      end
    end
  end
  im.Begin("Rally Toolbox", rallyToolboxWindowOpen)
    -- rallyToolbox:refresh()
    rallyToolbox:draw()
  im.End()
end

local function drawCalibrationWindow()
  CalibrationWindow.draw(M, calibrationWindowOpen)
end

local function openStageLoaderModal()
  stageLoaderOpen[0] = true
end

local function drawStageLoaderModal()
  StageLoaderModal.draw(M, stageLoaderOpen)
end

local function drawToolbarMissionContext(pathObj)
  if not currentMissionName then return end

  im.SameLine()
  local notebookBasename = pathObj and pathObj.basenameNoExt and pathObj:basenameNoExt() or '?'
  local voicepackDirname = currentVoicepackPick and currentVoicepackPick.dirname or '?'
  im.TextColored(im.ImVec4(0, 1, 1, 1), string.format("%s | %s | %s", tostring(currentMissionName), tostring(notebookBasename), tostring(voicepackDirname)))
  if currentMissionId then
    im.tooltip(string.format("Mission: %s\nNotebook: %s\nVoicepack: %s", tostring(currentMissionId), tostring(notebookBasename), tostring(voicepackDirname)))
  end
end

-- local generateAllFreeformPopup = false
local function drawEditorGui(dtReal, dtSim, dtRaw)
  -- idk what this is supposed to do.
  -- if focusWindow == true then
  --   im.SetNextWindowFocus()
  --   focusWindow = false
  -- end

  -- if editor.beginWindow(toolWindowName, "Rally Editor") then
  if editor.beginWindow(toolWindowName, "Rally Editor", im.WindowFlags_MenuBar) then
    if im.BeginMenuBar() then

      if im.BeginMenu("File") then
        if im.MenuItem1("Open Rally Stage...") then
          editor_rallyEditor.openStageLoaderModal()
        end
        if im.MenuItem1("Clear") then
          clearNotebook()
        end
        im.EndMenu()
      end -- end file menu

      if im.BeginMenu("View") then
        local labelMode = getPacenoteLabelModePreference()
        local labelModeText = pacenoteLabelModeLabels[labelMode] or pacenoteLabelModeLabels[pacenoteLabelModeDistance]

        im.Text("Pacenote labels")
        im.SameLine()
        im.SetNextItemWidth(220)
        if im.BeginCombo("##pacenoteLabelMode", labelModeText) then
          for _,mode in ipairs(pacenoteLabelModeValues) do
            local selected = labelMode == mode
            if im.Selectable1(pacenoteLabelModeLabels[mode], selected) then
              setPacenoteLabelModePreference(mode)
              labelMode = mode
            end
          end
          im.EndCombo()
        end
        if viewDefaultButton("resetPacenoteLabelMode", "Reset to default (Show near camera)") then
          setPacenoteLabelModePreference(pacenoteLabelModeDistance)
          labelMode = pacenoteLabelModeDistance
          labelModeText = pacenoteLabelModeLabels[labelMode]
        end

        local distancePtr = im.FloatPtr(getPacenoteLabelDistancePreference())
        local distanceDisabled = labelMode == pacenoteLabelModeAll
        if distanceDisabled then im.BeginDisabled() end
        im.Text("Overview distance")
        im.SameLine()
        im.SetNextItemWidth(220)
        if im.SliderFloat("##pacenoteLabelDistance", distancePtr, pacenoteLabelDistanceMin, pacenoteLabelDistanceMax, "%.0fm") then
          setPacenoteLabelDistancePreference(distancePtr[0])
        end
        if viewDefaultButton("resetPacenoteLabelDistance", "Reset to default (650m)") then
          setPacenoteLabelDistancePreference(pacenoteLabelDistanceDefault)
        end
        if distanceDisabled then im.EndDisabled() end

        local nearCameraCountPtr = im.IntPtr(getPacenoteLabelNearCameraCountPreference())
        if distanceDisabled then im.BeginDisabled() end
        im.Text("Nearby count")
        im.SameLine()
        im.SetNextItemWidth(220)
        if im.SliderInt("##pacenoteLabelNearCameraCount", nearCameraCountPtr, pacenoteLabelNearCameraCountMin, pacenoteLabelNearCameraCountMax) then
          setPacenoteLabelNearCameraCountPreference(nearCameraCountPtr[0])
        end
        im.tooltip("Number of pacenotes to label before and after the camera pivot.")
        if viewDefaultButton("resetPacenoteLabelNearCameraCount", "Reset to default (3)") then
          setPacenoteLabelNearCameraCountPreference(pacenoteLabelNearCameraCountDefault)
        end
        if distanceDisabled then im.EndDisabled() end

        local adjacentTextPtr = im.BoolPtr(getShowAdjacentPacenoteTextPreference())
        if im.Checkbox("Show Next and previous pacenote text", adjacentTextPtr) then
          setShowAdjacentPacenoteTextPreference(adjacentTextPtr[0])
        end
        im.tooltip("Show preview text labels on the rendered previous and next pacenotes when a pacenote is selected.")

        local selectedUtilityPtr = im.BoolPtr(getShowSelectedPacenoteUtilityPreference())
        if im.Checkbox("Show selected pacenote utility", selectedUtilityPtr) then
          setShowSelectedPacenoteUtilityPreference(selectedUtilityPtr[0])
        end
        im.tooltip("Show the floating selected-pacenote utility window.")

        local drivelineWidthPtr = im.FloatPtr(getDrivelineSplinePrismWidthPreference())
        im.Text("Driveline width")
        im.SameLine()
        im.SetNextItemWidth(220)
        if im.SliderFloat("##drivelineSplinePrismWidth", drivelineWidthPtr, drivelineSplinePrismWidthMin, drivelineSplinePrismWidthMax, "%.3fm") then
          setDrivelineSplinePrismWidthPreference(drivelineWidthPtr[0])
        end
        if viewDefaultButton("resetDrivelineSplinePrismWidth", "Reset to default (Vivace rally car track width)") then
          setDrivelineSplinePrismWidthPreference(drivelineSplinePrismWidthDefault)
        end

        local hideTheForestPtr = im.BoolPtr(hideTheForest)
        if im.Checkbox('Hide "theForest"', hideTheForestPtr) then
          setHideTheForest(hideTheForestPtr[0])
        end
        im.tooltip('Hide or show the SceneTree object named "theForest".')

        local snaproadPathOnTopPtr = im.BoolPtr(snaproadPathOnTop)
        if im.Checkbox("Snap-road On-Top", snaproadPathOnTopPtr) then
          snaproadPathOnTop = snaproadPathOnTopPtr[0]
        end
        im.tooltip("Render the red snap-road path through scene geometry.")

        im.EndMenu()
      end -- end view menu

      if im.BeginMenu("Tools") then
        if im.MenuItem1("Toggle DevTools window") then
          devTools = nil
          devToolsWindowOpen[0] = true
        end
        if im.MenuItem1("Toggle RallyToolbox window") then
          rallyToolbox = nil -- start fresh every time
          rallyToolboxWindowOpen[0] = true
        end
        local loopLoaded = extensions.isExtensionLoaded('gameplay_rallyLoop')
        local ptr = im.BoolPtr(loopLoaded or false)
        if im.Checkbox('RallyLoop Extension', ptr) then
          if ptr[0] then
            extensions.load('gameplay_rallyLoop')
          else
            extensions.unload('gameplay_rallyLoop')
          end
        end

        -- if im.MenuItem1("Generate All Freeform") then
        --   if currentPath then
        --     generateAllFreeformPopup = true
        --   end
        -- end
        -- im.tooltip("Generate all freeform notes from structured notes.")

        im.EndMenu()
      end -- end tools menu

      -- if im.BeginMenu("Preferences") then
      --   im.SetNextItemWidth(70)
      --   if im.BeginCombo('Rally Editor Preferred Snaproad Type##preferredSnaproadType', editor.getPreference("rallyEditor.editing.preferredSnaproadType")) then
      --     for _, snaproadType in ipairs(RallyEnums.drivelineModeNames) do
      --       if im.Selectable1(snaproadType, snaproadType == editor.getPreference("rallyEditor.editing.preferredSnaproadType")) then
      --         setPreferredSnaproadType(snaproadType)
      --       end
      --     end
      --     im.EndCombo()
      --   end
      --   im.EndMenu()
      -- end -- end preferences menu

      im.EndMenuBar()
    end -- end menu bar

    -- if generateAllFreeformPopup then
    --   im.OpenPopup("Generate All Freeform##genAllFreeform")
    --   generateAllFreeformPopup = nil
    -- end

    -- if im.BeginPopupModal("Generate All Freeform##genAllFreeform", nil, im.WindowFlags_AlwaysAutoResize) then
    --   im.Text("Generate all freeform notes from structured notes?")
    --   im.Text("Text for all freeform pacenotes may be changed.")
    --   im.Text("Make a backup before proceeding.")
    --   im.Separator()
    --   if im.Button("Ok", im.ImVec2(120,0)) then
    --     if currentPath then
    --       currentPath:generateAllFreeform()
    --     end
    --     im.CloseCurrentPopup()
    --   end
    --   im.SameLine()
    --   if im.Button("Cancel", im.ImVec2(120,0)) then
    --     im.CloseCurrentPopup()
    --   end
    --   im.EndPopup()
    -- end

    if currentMissionDir then
      -- Save button (disabled when no notebook is loaded).
      local saveDisabled = currentPath == nil
      if saveDisabled then im.BeginDisabled() end
      im.PushStyleColor2(im.Col_Button, im.ImColorByRGB(0,100,0,255).Value)
      if im.Button("Save") then
        saveNotebook()
      end
      im.PopStyleColor(1)
      if saveDisabled then im.EndDisabled() end

      -- im.SameLine()
      -- im.Text("Mission:")
      -- im.SameLine()
      -- im.Text(tostring(currentMissionName or '?'))
      -- if currentMissionId then im.tooltip(currentMissionId) end

      if currentPath then
        im.SameLine()
        local savedAt = tonumber(currentPath.updated_at or currentPath.created_at)
        if savedAt then
          local diff = math.max(0, os.time() - savedAt)
          if diff > 3600*24 then
            im.Text(string.format("saved %dd ago", math.floor(diff / (3600*24))))
          elseif diff > 3600 then
            im.Text(string.format("saved %dh ago", math.floor(diff / 3600)))
          elseif diff > 60 then
            im.Text(string.format("saved %dm ago", math.floor(diff / 60)))
          else
            im.Text(string.format("saved %ds ago", diff))
          end
        else
          im.Text("not saved yet")
        end
        editor_rallyEditor.drawToolbarMissionContext(currentPath)
      end

      if currentPath and (not editor.editMode or editor.editMode.displayName ~= editModeName) then
        im.PushStyleColor2(im.Col_Button, im.ImColorByRGB(255,0,0,255).Value)
        im.PushStyleColor2(im.Col_Text, im.ImColorByRGB(0,0,0,255).Value)
        if im.Button("Switch to Rally Editor Editmode", im.ImVec2(im.GetContentRegionAvailWidth(),0)) then
          editor.selectEditMode(editor.editModes.notebookEditMode)
        end
        im.PopStyleColor(2)
      end
      if currentPath then im.tooltip(tostring(currentPath.fname)) end

      -- im.SameLine()
      -- im.Text(""..tostring(currentPath.fname))

      -- im.Text("Mission: "..tostring(currentPath:getMissionId()))
      -- im.SameLine()
      -- if im.Button("Open Mission Editor") then
      --   openMission()
      -- end

      -- im.Text('DragMode: '..pacenotesWindow.pacenote_tools_state.drag_mode)

      -- local selParts, selMode = pacenotesWindow:selectionString()

      -- local clr = im.ImVec4(1, 0.6, 1, 1)
      -- im.PushFont3('robotomono_regular')
      -- im.TextColored(clr, 'Selection')
      -- im.TextColored(clr, '  P: '..(selParts[1] or '-'))
      -- im.TextColored(clr, '  W: '..(selParts[2] or '-'))
      -- im.PopFont()

      -- im.EndChild() -- end top-toolbar

      for i = 1,3 do im.Spacing() end

      -- local windowSize = im.GetWindowSize()
      -- local windowHeight = windowSize.y
      -- local middleChildHeight = windowHeight - topToolbarHeight - bottomToolbarHeight - heightAdditional
      -- local middleChildHeight = 1000
      -- middleChildHeight = math.max(middleChildHeight, minMiddleHeight)

      -- im.BeginChild1("##tabs-child", im.ImVec2(0,middleChildHeight), im.WindowFlags_ChildWindow and im.ImGuiWindowFlags_NoBorder )
      im.BeginChild1("##tabs-child", nil, im.WindowFlags_ChildWindow and im.ImGuiWindowFlags_NoBorder )
      if im.BeginTabBar("modes2") then
        for _, window in ipairs(windows) do

          local flags = nil
          if changedWindow and currentWindow.windowDescription == window.windowDescription then
            flags = im.TabItemFlags_SetSelected
            changedWindow = false
          end

          local hasError = false
          if window.isValid then
            hasError = not window:isValid()
          end

          local tabName = (hasError and '[!] ' or '')..' '..window.windowDescription..' '..'###'..window.windowDescription

          if im.BeginTabItem(tabName, nil, flags) then
            if not programmaticTabSelect and currentWindow.windowDescription ~= window.windowDescription then
              select(window)
            end
            im.EndTabItem()
          end

        end -- for loop
        programmaticTabSelect = false
        im.EndTabBar()
      end -- tab bar

      -- local tabsHeight = 25 * im.uiscale[0]
      -- local tabContentsHeight = middleChildHeight - tabsHeight
      -- im.BeginChild1("##tab-contents-child-window", im.ImVec2(0,tabContentsHeight), im.WindowFlags_ChildWindow and im.ImGuiWindowFlags_NoBorder)
      im.BeginChild1("##tab-contents-child-window", nil, im.WindowFlags_ChildWindow and im.ImGuiWindowFlags_NoBorder)
      if currentPath or currentWindow == aiCompetitorsWindow then
        currentWindow:draw(mouseInfo, dtReal, dtSim, dtRaw)
      else
        im.HeaderText("No notebook loaded")
        im.TextWrapped("Open an existing Rally Stage mission from the current level to start editing its notebook.")
        if im.Button("Open Rally Stage...") then
          editor_rallyEditor.openStageLoaderModal()
        end
      end
      im.EndChild() -- end top-toolbar

      im.EndChild() -- end tabs-child

      if currentPath then
        local fg_mgr = editor_flowgraphEditor.getManager()
        local paused = simTimeAuthority.getPause()
        local is_path_cam = core_camera.getActiveCamName() == "path"

        if not is_path_cam then
          if currentWindow == pacenotesWindow then
            pacenotesWindow:drawDebugEntrypoint(debugDrawOpacity, dtSim)
          elseif currentWindow == recceWindow then
            recceWindow:drawDebugEntrypoint(mouseInfo)
          elseif currentWindow == drivelineWindow then
            drivelineWindow:drawDebugEntrypoint(mouseInfo)
          elseif currentWindow == testWindow then
            testWindow:drawDebugEntrypoint()
          end
        else
          if currentWindow == pacenotesWindow then
            pacenotesWindow:drawDebugCameraPlaying()
          end
        end
      end

    else
      im.HeaderText("No notebook loaded")
      im.TextWrapped("Open an existing Rally Stage mission from the current level to start editing its notebook.")
      if im.Button("Open Rally Stage...") then
        editor_rallyEditor.openStageLoaderModal()
      end
    end -- if currentMissionDir


    updateMouseInfo()
    moveWaypointWithDebounce()
    zoomWithDebounce()
    editor_rallyEditor.drawStageLoaderModal()
  end

  editor.endWindow()

  if not editor.isWindowVisible(toolWindowName) and editor.editModes and editor.editModes.displayName == editModeName then
    editor.selectEditMode(nil)
  end

  drawDevTools()
  drawRallyToolbox()
  drawCalibrationWindow()
end

local function onEditorGui(dtReal, dtSim, dtRaw)
  drawEditorGui(dtReal, dtSim, dtRaw)
end

local function showPacenotesTab()
  programmaticTabSelect = true
  select(pacenotesWindow)
end

local function showRallyTool()
  if editor.isWindowVisible(toolWindowName) == false then
    editor.showWindow(toolWindowName)
    showPacenotesTab()
    editor.selectEditMode(editor.editModes.notebookEditMode)
  else
    focusWindow = true
    showPacenotesTab()
    editor.selectEditMode(editor.editModes.notebookEditMode)
  end
end

local function show()
  editor.clearObjectSelection()
  editor.showWindow(toolWindowName)
  editor.selectEditMode(editor.editModes.notebookEditMode)
end

local function onActivate()
  editor.clearObjectSelection()
  for _, win in ipairs(windows) do
    if win.onEditModeActivate then
      win:onEditModeActivate()
    end
  end
end

local function onDeactivate()
  for _, win in ipairs(windows) do
    if win.onEditModeDeactivate then
      win:onEditModeDeactivate()
    end
  end
  resetEphemeralViewOptions()
  editor.clearObjectSelection()
end

local function onDeleteSelection()
  if not editor.isViewportFocused() then return end

  if currentWindow == pacenotesWindow then
    pacenotesWindow:deleteSelected()
  end
end

-- local function onUpdate(dtReal, dtSim, dtRaw)
-- end

-- this is called after you Ctrl+L to reload lua.
local function onEditorInitialized()
  isDev = devTxtExists()
  -- print('isDev='..tostring(isDev))
  log('I', logTag, string.format('onEditorInitialized begin: clearing stale window refs windowCount=%d currentWindow=%s', #windows, tostring(currentWindow and currentWindow.windowDescription)))
  table.clear(windows)
  pacenotesWindow = nil
  recceWindow = nil
  testWindow = nil
  drivelineWindow = nil
  aiCompetitorsWindow = nil
  currentWindow = {}
  changedWindow = false
  programmaticTabSelect = false
  ghostNotebook = GhostNotebook(M)

  editor.editModes.notebookEditMode =
  {
    displayName = editModeName,
    -- onUpdate = onUpdate,
    onUpdate = nop,
    onActivate = onActivate,
    onDeactivate = onDeactivate,
    onDeleteSelection = onDeleteSelection,
    actionMap = "rallyEditor", -- if available, not required
    auxShortcuts = {},
    --icon = editor.icons.tb_close_track,
    --iconTooltip = "Race Editor"
  }
  editor.editModes.notebookEditMode.auxShortcuts[editor.AuxControl_LMB] = "Select"
  editor.registerWindow(toolWindowName, im.ImVec2(500, 500))
  editor.addWindowMenuItem("Rally Editor", function() show() end,{groupMenuName="Gameplay"})

  table.insert(windows, require('/lua/ge/extensions/editor/rallyEditor/notebookInfo')(M))
  table.insert(windows, require('/lua/ge/extensions/editor/rallyEditor/missionTab')(M))
  table.insert(windows, require('/lua/ge/extensions/editor/rallyEditor/voicepacksTab')(M))

  pacenotesWindow = require('/lua/ge/extensions/editor/rallyEditor/pacenotes')(M)
  table.insert(windows, pacenotesWindow)

  -- recceWindow = require('/lua/ge/extensions/editor/rallyEditor/recceTab')(M)
  -- table.insert(windows, recceWindow)

  drivelineWindow = require('/lua/ge/extensions/editor/rallyEditor/drivelineTab')(M)
  table.insert(windows, drivelineWindow)

  table.insert(windows, require('/lua/ge/extensions/editor/rallyEditor/systemPacenotesTab')(M))
  table.insert(windows, require('/lua/ge/extensions/editor/rallyEditor/measurementsTab')(M))
  aiCompetitorsWindow = require('/lua/ge/extensions/editor/rallyEditor/aiCompetitorsTab')(M)
  table.insert(windows, aiCompetitorsWindow)

  if isDev then
    testWindow = require('/lua/ge/extensions/editor/rallyEditor/testTab')(M)
    table.insert(windows, testWindow)
  end

  for _, win in pairs(windows) do
    if win.setPath then
      win:setPath(currentPath)
    end
  end

  pacenotesWindow:attemptToFixMapEdgeIssue()

  currentWindow = pacenotesWindow
  if currentWindow.selected then
    currentWindow:selected()
  end
  if not currentPath then
    programmaticTabSelect = true
    select(aiCompetitorsWindow)
  end
end

local function onEditorToolWindowHide(windowName)
  if windowName == toolWindowName then
    editor.selectEditMode(editor.editModes.objectSelect)
  end
end

local function onWindowGotFocus(windowName)
  if windowName == toolWindowName then
    editor.selectEditMode(editor.editModes.notebookEditMode)
  end
end

local function onSerialize()
  local currentNotebookFname = currentPath and currentPath.fname or nil
  return {
    currentMissionDir      = currentMissionDir,
    currentVoicepackPick   = currentVoicepackPick,
    currentNotebookFname   = currentNotebookFname,
    rallyToolboxWindowOpen = rallyToolboxWindowOpen[0],
    devToolsWindowOpen     = devToolsWindowOpen[0],
  }
end

local function onDeserialized(data)
  if not data then return end

  if data.currentMissionDir then
    setCurrentMission(data.currentMissionDir)
  end

  currentVoicepackPick = data.currentVoicepackPick
  -- legacy 'custom' picks predate the unified mission-voicepack model; drop them so the picker
  -- auto-selects something valid on first draw.
  if currentVoicepackPick and currentVoicepackPick.type == 'custom' then
    currentVoicepackPick = nil
  end

  if data.currentNotebookFname and FS:fileExists(data.currentNotebookFname) then
    loadNotebook(data.currentNotebookFname)
  else
    if data.currentNotebookFname then
      log('W', logTag, 'persisted notebook no longer exists: '..tostring(data.currentNotebookFname))
    end
    -- Fall back to picking the first candidate of the persisted voicepack pick, if any.
    if currentMissionDir and currentVoicepackPick then
      local basenames = voicepack.notebookBasenamesForPick(currentMissionDir, currentVoicepackPick)
      if basenames[1] then
        local fallbackNotebook = rallyUtil.getNotebookFullPath(currentMissionDir, basenames[1]..'.notebook.json')
        loadNotebook(fallbackNotebook)
      end
    end
  end

  rallyToolboxWindowOpen = im.BoolPtr(data.rallyToolboxWindowOpen and true or false)
  devToolsWindowOpen     = im.BoolPtr(data.devToolsWindowOpen and true or false)
end

local function onEditorRegisterPreferences(prefsRegistry)
  prefsRegistry:registerCategory("rallyEditor")

  prefsRegistry:registerSubCategory("rallyEditor", "editing", nil, {
    -- {name = {type, default value, desc, label (nil for auto Sentence Case), min, max, hidden, advanced, customUiFunc, enumLabels}}
    {lockWaypoints = {"bool", false, "Lock position of waypoints.", "Lock waypoints", nil, nil, true}},
    {showPreviousPacenote = {"bool", true, "When a pacenote is selected, also render the previous pacenote for reference."}},
    {showNextPacenote = {"bool", true, "When a pacenote is selected, also render the next pacenote for reference."}},
    {waypointSnapMethod = {"enum", zSnap.defaultMethod, "How waypoint dragging snaps Z before finding the closest snaproad point.", "Waypoint snap method", nil, nil, nil, nil, nil, zSnap.methodValues}},
    -- {preferredSnaproadType = {"enum", "route", "Preferred snaproad type to use for the rally editor.", nil, nil, nil, true, nil, nil, RallyEnums.drivelineModeNames}},
  })

  prefsRegistry:registerSubCategory("rallyEditor", "view", nil, {
    {pacenoteLabelMode = {"enum", pacenoteLabelModeDistance, "How background pacenote preview labels are shown.", "Pacenote label mode", nil, nil, nil, nil, nil, pacenoteLabelModeValues}},
    {pacenoteLabelDistance = {"float", pacenoteLabelDistanceDefault, "Camera distance where no-selection pacenote preview switches to rainbow overview.", "Pacenote overview distance", pacenoteLabelDistanceMin, pacenoteLabelDistanceMax}},
    {pacenoteLabelNearCameraCount = {"int", pacenoteLabelNearCameraCountDefault, "Number of pacenotes before and after the camera pivot that show labels.", "Pacenote label nearby count", pacenoteLabelNearCameraCountMin, pacenoteLabelNearCameraCountMax}},
    {showAdjacentPacenoteText = {"bool", true, "Show preview text labels on the rendered previous and next pacenotes.", "Show Next and previous pacenote text"}},
    {showSelectedPacenoteUtility = {"bool", false, "Show the floating selected-pacenote utility window.", "Show selected pacenote utility"}},
    {drivelineSplinePrismWidth = {"float", drivelineSplinePrismWidthDefault, "Vehicle-width prism used for drawing the calculated driveline spline.", "Driveline width", drivelineSplinePrismWidthMin, drivelineSplinePrismWidthMax}},
    {showAllPacenoteLabels = {"bool", false, "Legacy preference for showing preview labels for all pacenotes.", "Show all pacenote labels", nil, nil, true}},
  })

  prefsRegistry:registerSubCategory("rallyEditor", "waypoints", nil, {
    {defaultRadius = {"int", 8, "The radius used for displaying waypoints.", "Visual Radius", 1, 50}},
  })

  prefsRegistry:registerSubCategory("rallyEditor", "ui", nil, {
    {pacenoteNoteFieldWidth = {"int", 300, "Width of pacenote notes.note.freeform field.", nil, 1, 1000}},
  })
end

local function getPreference(key, default)
  if editor and editor.getPreference then
    local value = editor.getPreference(key)
    if value ~= nil then
      return value
    end
  else
    return default
  end
  return default
end

local function getPrefShowPreviousPacenote()
  return getPreference('rallyEditor.editing.showPreviousPacenote', true)
end

local function getPrefShowNextPacenote()
  return getPreference('rallyEditor.editing.showNextPacenote', true)
end

local function getPrefShowAllPacenoteLabels()
  return getPacenoteLabelModePreference() == pacenoteLabelModeAll
end

local function getPrefPacenoteLabelMode()
  return getPacenoteLabelModePreference()
end

local function getPrefPacenoteLabelDistance()
  return getPacenoteLabelDistancePreference()
end

local function getPrefPacenoteLabelNearCameraCount()
  return getPacenoteLabelNearCameraCountPreference()
end

local function getPrefShowAdjacentPacenoteText()
  return getShowAdjacentPacenoteTextPreference()
end

local function getPrefShowSelectedPacenoteUtility()
  return getShowSelectedPacenoteUtilityPreference()
end

local function getPrefDrivelineSplinePrismWidth()
  return getDrivelineSplinePrismWidthPreference()
end

local function getPrefDefaultRadius()
  return getPreference('rallyEditor.waypoints.defaultRadius', rallyUtil.default_waypoint_intersect_radius)
end

local function getPrefUiPacenoteNoteFieldWidth()
  return getPreference('rallyEditor.ui.pacenoteNoteFieldWidth', 300)
end

local function getPrefLockWaypoints()
  return getPreference("rallyEditor.editing.lockWaypoints", false)
end

local function getPrefWaypointSnapMethod()
  local value = getPreference('rallyEditor.editing.waypointSnapMethod', zSnap.defaultMethod)
  return zSnap.isValidMethod(value) and value or zSnap.defaultMethod
end

local function setPrefLockWaypoints(val)
  editor.setPreference("rallyEditor.editing.lockWaypoints", val)
end

local function listNotebooks(folder)
  if not folder then
    folder = currentPath:getMissionDir()
  end
  local notebooksFullPath = folder..'/'..rallyUtil.notebooksPath
  local paths = {}
  log('I', logTag, 'loading all notebook names from '..notebooksFullPath)
  local files = FS:findFiles(notebooksFullPath, '*.notebook.json', -1, true, false)
  for _,fname in pairs(files) do
    table.insert(paths, fname)
  end
  table.sort(paths)

  log("D", logTag, dumps(paths))

  return paths
end

local function listGhostNotebookChoices()
  if not ghostNotebook then return {} end
  return ghostNotebook:listChoices()
end

local function selectGhostNotebook(fname)
  if not ghostNotebook then return false end
  return ghostNotebook:select(fname)
end

local function clearGhostNotebook()
  if ghostNotebook then
    ghostNotebook:clear()
  end
end

local function getGhostNotebookPath()
  return ghostNotebook and ghostNotebook:getPath() or nil
end

local function getGhostNotebookSelectedFname()
  return ghostNotebook and ghostNotebook:getSelectedFname() or nil
end

local function getGhostNotebookSelectedLabel()
  return ghostNotebook and ghostNotebook:getSelectedLabel() or '(none)'
end

local function getGhostNotebookError()
  return ghostNotebook and ghostNotebook:getError() or nil
end

local function getGhostNotebookLabelForPacenote(pacenote)
  return ghostNotebook and ghostNotebook:getLabelForPacenote(pacenote) or nil
end

local missionEditorDefaultNotebookFname = 'structured.notebook.json'

local function detectNotebookToLoad(missionDir)
  log('D', logTag, 'detectNotebookToLoad missionDir: '..missionDir)

  -- Try the voicepack-driven resolver first (cascade settings; editor has no toolbox pick).
  local _, vpEntry = voicepack.resolveEffectiveEntry(missionDir, nil)
  local notebookFname = voicepack.resolveMissionNotebook(missionDir, vpEntry)

  -- Fallback for editing: pick the first notebook found in the mission, or create the
  -- structured notebook that current voicepack resolution can discover later.
  if not notebookFname then
    local existing = rallyUtil.listNotebooks(missionDir)
    if existing[1] then
      notebookFname = rallyUtil.getNotebookFullPath(missionDir, existing[1])
    else
      notebookFname = rallyUtil.getNotebookFullPath(missionDir, missionEditorDefaultNotebookFname)
    end
  end

  log('D', logTag, 'detectNotebookToLoad final notebookFname: '..tostring(notebookFname))
  return notebookFname
end

local function loadForMissionEditor(missionDir)
  setCurrentMission(missionDir)

  local entries = voicepack.buildPickerEntries(missionDir, { missionSuffix = '(mission)' })
  if entries[1] then
    setVoicepackPick(entries[1].pick)
  else
    currentVoicepackPick = nil
    clearNotebook()
  end
end

local function loadOrCreateForMissionEditor(missionDir)
  setCurrentMission(missionDir)
  currentVoicepackPick = nil

  local notebookFname = detectNotebookToLoad(missionDir)
  if notebookFname then
    loadOrCreateNotebook(notebookFname)
  else
    clearNotebook()
  end
end

local function getCurrentFilename()
  if currentPath then
    return currentPath.fname
  else
    return nil
  end
end

local function changeDebugDrawOpacity(val)
  local incr = 0.2
  if val == 0 then
    debugDrawOpacity = debugDrawOpacity - incr
  elseif val == 1.0 then
    debugDrawOpacity = debugDrawOpacity + incr
  end
  local minOpacity = 0.1
  if debugDrawOpacity > 1.0 then debugDrawOpacity = 1.0 end
  if debugDrawOpacity < minOpacity then debugDrawOpacity = minOpacity end
end

local function mouseWheelZoom(val)
  if core_camera and core_camera.getActiveCamName() == 'pacenoteOrbit' then
    if val == 0 then
      core_camera.cameraZoom(0.4)
    elseif val == 1.0 then
      core_camera.cameraZoom(-0.4)
    end
  end
end

-- called directly by the input action
local function zoomIn(val)
  if not (core_camera and core_camera.getActiveCamName() == 'pacenoteOrbit') then
    return
  end

  if val == 0 then
    zoomState.lastZoomTs = 0
  end

  zoomState.zoomIn = val
end

-- called directly by the input action
local function zoomOut(val)
  if not (core_camera and core_camera.getActiveCamName() == 'pacenoteOrbit') then
    return
  end

  if val == 0 then
    zoomState.lastZoomTs = 0
  end

  zoomState.zoomOut = val
end

local function isToolboxOpen()
  return rallyToolboxWindowOpen[0] or devToolsWindowOpen[0]
end

local function onVehicleResetted()
  if devTools and devToolsWindowOpen[0] then
    devTools:onVehicleResetted()
  end
end

M.onEditorRegisterPreferences = onEditorRegisterPreferences
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onVehicleResetted = onVehicleResetted
M.allowGizmo = function() return editor.editMode and editor.editMode.displayName == editModeName or false end
-- M.getCurrentFilename = function() return previousFilepath..previousFilename end
M.getCurrentFilename = getCurrentFilename
M.getCurrentPath = function() return currentPath end
M.getCurrentMissionDir  = function() return currentMissionDir end
M.getCurrentMissionName = function() return currentMissionName end
M.getCurrentMissionId   = function() return currentMissionId end
M.getCurrentVoicepackPick   = function() return currentVoicepackPick end
M.setVoicepackPick          = setVoicepackPick
-- Thin facades over voicepack.lua kept for backwards compatibility with external callers.
M.picksMatch                = voicepack.picksMatch
M.buildVoicepackPickerEntries = function(missionDir) return voicepack.buildPickerEntries(missionDir, { missionSuffix = '(mission)' }) end
M.notebookBasenamesForPick    = voicepack.notebookBasenamesForPick
M.isVisible = function() return editor.isWindowVisible(toolWindowName) end
M.show = show
M.showRallyTool = showRallyTool
M.showPacenotesTab = showPacenotesTab
M.openStageLoaderModal = openStageLoaderModal
M.drawStageLoaderModal = drawStageLoaderModal
M.drawToolbarMissionContext = drawToolbarMissionContext
M.getViewSnaproadPathOnTop = function() return snaproadPathOnTop end
M.loadNotebook = loadNotebook
M.loadOrCreateNotebook = loadOrCreateNotebook
M.saveNotebook = saveNotebook
M.listGhostNotebookChoices = listGhostNotebookChoices
M.selectGhostNotebook = selectGhostNotebook
M.clearGhostNotebook = clearGhostNotebook
M.getGhostNotebookPath = getGhostNotebookPath
M.getGhostNotebookSelectedFname = getGhostNotebookSelectedFname
M.getGhostNotebookSelectedLabel = getGhostNotebookSelectedLabel
M.getGhostNotebookError = getGhostNotebookError
M.getGhostNotebookLabelForPacenote = getGhostNotebookLabelForPacenote
M.onEditorGui = onEditorGui
M.onEditorToolWindowHide = onEditorToolWindowHide
M.onWindowGotFocus = onWindowGotFocus
M.detectNotebookToLoad = detectNotebookToLoad
M.listNotebooks = listNotebooks
M.selectPrevPacenote = selectPrevPacenote
M.selectNextPacenote = selectNextPacenote
-- M.cycleDragMode = cycleDragMode
M.insertMode = insertMode
M.setFreeCam = setFreeCam
M.deselect = deselect
M.selectNextWaypoint = selectNextWaypoint
M.moveSelectedWaypointForward = moveSelectedWaypointForward
M.moveSelectedWaypointBackward = moveSelectedWaypointBackward
-- M.moveSelectedWaypointForwardFast = moveSelectedWaypointForwardFast
-- M.moveSelectedWaypointBackwardFast = moveSelectedWaypointBackwardFast
M.cameraPathPlay = cameraPathPlay
M.toggleCornerCalls = toggleCornerCalls
M.onEditorInitialized = onEditorInitialized
M.getPrefDefaultRadius = getPrefDefaultRadius
M.getPrefLockWaypoints = getPrefLockWaypoints
M.getPrefWaypointSnapMethod = getPrefWaypointSnapMethod
M.setPrefLockWaypoints = setPrefLockWaypoints
M.getPrefShowNextPacenote = getPrefShowNextPacenote
M.getPrefShowPreviousPacenote = getPrefShowPreviousPacenote
M.getPrefShowAllPacenoteLabels = getPrefShowAllPacenoteLabels
M.getPrefPacenoteLabelMode = getPrefPacenoteLabelMode
M.getPrefPacenoteLabelDistance = getPrefPacenoteLabelDistance
M.getPrefPacenoteLabelNearCameraCount = getPrefPacenoteLabelNearCameraCount
M.getPrefShowAdjacentPacenoteText = getPrefShowAdjacentPacenoteText
M.getPrefShowSelectedPacenoteUtility = getPrefShowSelectedPacenoteUtility
M.getPrefDrivelineSplinePrismWidth = getPrefDrivelineSplinePrismWidth
M.getPrefUiPacenoteNoteFieldWidth = getPrefUiPacenoteNoteFieldWidth
M.changeDebugDrawOpacity = changeDebugDrawOpacity
M.mouseWheelZoom = mouseWheelZoom
M.zoomIn = zoomIn
M.zoomOut = zoomOut
M.devToolsWindowOpen = devToolsWindowOpen
M.rallyToolboxWindowOpen = rallyToolboxWindowOpen
M.isCalibrationWindowOpen = function() return calibrationWindowOpen[0] end
M.toggleCalibrationWindow = function() calibrationWindowOpen[0] = not calibrationWindowOpen[0] end
M.loadForMissionEditor = loadForMissionEditor
M.loadOrCreateForMissionEditor = loadOrCreateForMissionEditor
M.getVolatilePreferences = function() return volatilePreferences end
-- M.setPreferredSnaproadType = setPreferredSnaproadType
M.getPacenotesWindow = function() return pacenotesWindow end
M.getMissionDir = function() return currentPath and currentPath:getMissionDir() or nil end
M.getMissionId = function() return currentPath and currentPath:getMissionId() or nil end
M.isToolboxOpen = isToolboxOpen
M.isPacenotesToolsSectionExpanded = function() return devToolsWindowOpen[0] and devTools and devTools:isPacenotesToolsSectionExpanded() or false end

return M
