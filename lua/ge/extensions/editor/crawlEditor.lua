-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local gameplay_crawl_saveSystem = require('/lua/ge/extensions/gameplay/crawl/saveSystem')

local M = {}
local im = ui_imgui

local logTag = "crawl_editor"
local toolWindowName = "Crawl Data Editor"
local pathEditModeName = "Edit Pathnodes"
local boundaryEditModeName = "Edit Boundaries"
local trailEditModeName = "Edit Trail"

local boundaries = require('/lua/ge/extensions/editor/crawlEditor/boundaries')(M)
local paths = require('/lua/ge/extensions/editor/crawlEditor/paths')(M)
local trails = require('/lua/ge/extensions/editor/crawlEditor/trails')()
local startingPositions = require('/lua/ge/extensions/editor/crawlEditor/startingPositions')()
local input = require('/lua/ge/extensions/editor/crawlEditor/input')
local missionPortTool = require('/lua/ge/extensions/editor/crawlEditor/missionPortTool')

local currentFileDir = "settings/cloud/crawls/"
local currentFileName
local crawlData
local mouseInfo
local currentTab = "paths"

local allTrails = {}
local allPaths = {}
local allBoundaries = {}
local allStartingPositions = {}

local missionTrails = {}
local missionPaths = {}
local missionBoundaries = {}

local selectedTrailIndex = -1
local selectedPathIndex = -1
local selectedBoundaryIndex = -1
local selectedStartingPositionIndex = -1

local unsavedColor = im.ImVec4(1, 0.3, 0.1, 1.0)


local function updateReferences(oldFilePath, newFilePath, objectType)
  if not oldFilePath or not newFilePath or oldFilePath == newFilePath then
    return
  end

  for _, trail in ipairs(allTrails) do
    local updated = false

    if objectType == "path" and trail.pathId == oldFilePath then
      trail.pathId = newFilePath
      updated = true
    elseif objectType == "boundary" and trail.boundaryId == oldFilePath then
      trail.boundaryId = newFilePath
      updated = true
    elseif objectType == "startingPosition" and trail.startingPositionId == oldFilePath then
      trail.startingPositionId = newFilePath
      updated = true
    elseif objectType == "startingPosition" and trail.startingPositionIdReversed == oldFilePath then
      trail.startingPositionIdReversed = newFilePath
      updated = true
    end

    if updated then
      gameplay_crawl_saveSystem.saveTrail(trail, trail._filePath)
    end
  end
end

local function renameObjectFile(oldFilePath, newFilePath, objectType)
  if not oldFilePath or not newFilePath or oldFilePath == newFilePath then
    return false
  end

  if FS:fileExists(newFilePath) then
    log('W', logTag, 'Cannot rename: target file already exists: ' .. newFilePath)
    return false
  end

  local success = FS:renameFile(oldFilePath, newFilePath)
  if not success then
    log('E', logTag, 'Failed to rename file from ' .. oldFilePath .. ' to ' .. newFilePath)
    return false
  end

  updateReferences(oldFilePath, newFilePath, objectType)

  local object = nil
  if objectType == "trail" then
    for _, trail in ipairs(allTrails) do
      if trail._filePath == oldFilePath then
        trail._filePath = newFilePath
        local _, fileName, _ = path.splitWithoutExt(newFilePath, true)
        trail._fileName = fileName
        object = trail
        break
      end
    end
  elseif objectType == "path" then
    for _, pathh in ipairs(allPaths) do
      if pathh._filePath == oldFilePath then
        pathh._filePath = newFilePath
        local _, fileName, _ = path.splitWithoutExt(newFilePath, true)
        pathh._fileName = fileName
        object = pathh
        break
      end
    end
  elseif objectType == "boundary" then
    for _, boundary in ipairs(allBoundaries) do
      if boundary._filePath == oldFilePath then
        boundary._filePath = newFilePath
        local _, fileName, _ = path.splitWithoutExt(newFilePath, true)
        boundary._fileName = fileName
        object = boundary
        break
      end
    end
  elseif objectType == "startingPosition" then
    for _, startingPosition in ipairs(allStartingPositions) do
      if startingPosition._filePath == oldFilePath then
        startingPosition._filePath = newFilePath
        local _, fileName, _ = path.splitWithoutExt(newFilePath, true)
        startingPosition._fileName = fileName
        object = startingPosition
        break
      end
    end
  end

  if object then
    if objectType == "trail" then
      gameplay_crawl_saveSystem.saveTrail(object, newFilePath)
    elseif objectType == "path" then
      gameplay_crawl_saveSystem.savePath(object, newFilePath)
    elseif objectType == "boundary" then
      gameplay_crawl_saveSystem.saveBoundary(object, newFilePath)
    elseif objectType == "startingPosition" then
      gameplay_crawl_saveSystem.saveStartingPosition(object, newFilePath)
    end
  end

  log('D', logTag, 'Successfully renamed ' .. objectType .. ' from ' .. oldFilePath .. ' to ' .. newFilePath)
  return true
end



local function getNewCrawlData()
  return {
    name = "New Crawl",
    description = "A new crawl location",
    icon = "rockCrawling01",
    trails = {},
    metadata = {
      version = "1.0",
      created = os.date(),
      description = "Crawl system data for this level"
    }
  }
end

local function loadAllObjects()
  local trailFiles = gameplay_crawl_saveSystem.getAllTrailFiles()
  local pathFiles = gameplay_crawl_saveSystem.getAllPathFiles()
  local boundaryFiles = gameplay_crawl_saveSystem.getAllBoundaryFiles()
  local startingPositionFiles = gameplay_crawl_saveSystem.getAllStartingPositionFiles()

  log('D', logTag, string.format('Found files - Trails: %d, Paths: %d, Boundaries: %d, Starting Positions: %d',
    #trailFiles, #pathFiles, #boundaryFiles, #startingPositionFiles))

  allTrails = {}
  allPaths = {}
  allBoundaries = {}
  allStartingPositions = {}
  missionTrails = {}
  missionPaths = {}
  missionBoundaries = {}

  for _, filePath in ipairs(trailFiles) do
    local trail = gameplay_crawl_saveSystem.getTrailById(filePath)
    if trail then
      table.insert(allTrails, trail)
    end
  end

  local currentLevel = getCurrentLevelIdentifier()
  if currentLevel then
    local missionsPath = "/gameplay/missions/" .. currentLevel .. "/crawl/"
    if FS:directoryExists(missionsPath) then
      local missionDirs = FS:findFiles(missionsPath, "*", 0, false, true)

      for _, missionDir in ipairs(missionDirs) do
        local stat = FS:stat(missionDir)
        if stat.filetype == "dir" then
          local missionName = string.match(missionDir, "([^/]+)/?$")
          if missionName then
            local trailFile = missionDir .. "/" .. missionName .. ".trail.json"
            local pathFile = missionDir .. "/" .. missionName .. ".path.json"
            local boundaryFile = missionDir .. "/" .. missionName .. ".boundary.json"

            if FS:fileExists(trailFile) then
              local trail = gameplay_crawl_saveSystem.getTrailById(trailFile)
              if trail then
                trail._isFromMission = true
                trail._missionName = missionName
                table.insert(missionTrails, trail)
              end
            end

            if FS:fileExists(pathFile) then
              local path = gameplay_crawl_saveSystem.getPathById(pathFile)
              if path then
                path._isFromMission = true
                path._missionName = missionName
                table.insert(missionPaths, path)
              end
            end

            if FS:fileExists(boundaryFile) then
              local boundary = gameplay_crawl_saveSystem.getBoundaryById(boundaryFile)
              if boundary then
                boundary._isFromMission = true
                boundary._missionName = missionName
                table.insert(missionBoundaries, boundary)
              end
            end
          end
        end
      end
    end
  end

  for _, filePath in ipairs(pathFiles) do
    local path = gameplay_crawl_saveSystem.getPathById(filePath)
    if path then
      table.insert(allPaths, path)
    end
  end

  for _, filePath in ipairs(boundaryFiles) do
    local boundary = gameplay_crawl_saveSystem.getBoundaryById(filePath)
    if boundary then
      table.insert(allBoundaries, boundary)
    end
  end

  for _, filePath in ipairs(startingPositionFiles) do
    local startingPosition = gameplay_crawl_saveSystem.getStartingPositionById(filePath)
    if startingPosition then
      table.insert(allStartingPositions, startingPosition)
    end
  end

  log('D', logTag, string.format('Loaded %d trails, %d mission trails, %d paths, %d mission paths, %d boundaries, %d mission boundaries, %d starting positions', #allTrails, #missionTrails, #allPaths, #missionPaths, #allBoundaries, #missionBoundaries, #allStartingPositions))
end

local function getSelectedTrail()
  if selectedTrailIndex > 0 and selectedTrailIndex <= #allTrails then
    return allTrails[selectedTrailIndex]
  elseif selectedTrailIndex > #allTrails and selectedTrailIndex <= #allTrails + #missionTrails then
    return missionTrails[selectedTrailIndex - #allTrails]
  end
  return nil
end

local function getSelectedPath()
  if selectedPathIndex > 0 and selectedPathIndex <= #allPaths then
    return allPaths[selectedPathIndex]
  elseif selectedPathIndex > #allPaths and selectedPathIndex <= #allPaths + #missionPaths then
    return missionPaths[selectedPathIndex - #allPaths]
  end
  return nil
end

local function getSelectedBoundary()
  if selectedBoundaryIndex > 0 and selectedBoundaryIndex <= #allBoundaries then
    return allBoundaries[selectedBoundaryIndex]
  elseif selectedBoundaryIndex > #allBoundaries and selectedBoundaryIndex <= #allBoundaries + #missionBoundaries then
    return missionBoundaries[selectedBoundaryIndex - #allBoundaries]
  end
  return nil
end

local function getSelectedStartingPosition()
  if selectedStartingPositionIndex > 0 and selectedStartingPositionIndex <= #allStartingPositions then
    return allStartingPositions[selectedStartingPositionIndex]
  end
  return nil
end

-- Keep only one object kind selected at a time so stale always-draw overlays don't linger.
local function selectOnly(kind)
  if kind ~= "trail" then selectedTrailIndex = 0 end
  if kind ~= "path" then selectedPathIndex = 0 end
  if kind ~= "boundary" then selectedBoundaryIndex = 0 end
  if kind ~= "startingPosition" then selectedStartingPositionIndex = 0 end
end

local function markAsDirty(objectType, index)
  if objectType == "trail" and index > 0 and index <= #allTrails then
    allTrails[index]._dirty = true
  elseif objectType == "trail" and index > #allTrails and index <= #allTrails + #missionTrails then
    missionTrails[index - #allTrails]._dirty = true
  elseif objectType == "path" and index > 0 and index <= #allPaths then
    allPaths[index]._dirty = true
  elseif objectType == "path" and index > #allPaths and index <= #allPaths + #missionPaths then
    missionPaths[index - #allPaths]._dirty = true
  elseif objectType == "boundary" and index > 0 and index <= #allBoundaries then
    allBoundaries[index]._dirty = true
  elseif objectType == "boundary" and index > #allBoundaries and index <= #allBoundaries + #missionBoundaries then
    missionBoundaries[index - #allBoundaries]._dirty = true
  elseif objectType == "startingPosition" and index > 0 and index <= #allStartingPositions then
    allStartingPositions[index]._dirty = true
  end
end

local function getAvailableMissions()
  local missions = {}
  local currentLevel = getCurrentLevelIdentifier()
  if not currentLevel then
    return missions
  end

  local missionsPath = "/gameplay/missions/" .. currentLevel .. "/crawl/"
  if not FS:directoryExists(missionsPath) then
    return missions
  end

  local missionDirs = FS:findFiles(missionsPath, "*", 0, false, true)
  for _, missionDir in ipairs(missionDirs) do
    local stat = FS:stat(missionDir)
    if stat.filetype == "dir" then
      local missionName = string.match(missionDir, "([^/]+)/?$")
      if missionName then
        table.insert(missions, missionName)
      end
    end
  end

  return missions
end

local function getNextMissionNumber()
  local missions = getAvailableMissions()
  local maxNumber = 0

  for _, missionName in ipairs(missions) do
    local number = tonumber(string.match(missionName, "^(%d+)"))
    if number and number > maxNumber then
      maxNumber = number
    end
  end

  return string.format("%03d", maxNumber + 1)
end

local function moveTrailToMission(trailIndex)
  local trail = allTrails[trailIndex]
  if not trail then
    log('E', 'crawl_editor', 'Trail not found at index: ' .. trailIndex)
    return false
  end

  local missionName = trail._fileName
  if not missionName then
    log('E', 'crawl_editor', 'Trail has no filename')
    return false
  end

  log('D', 'crawl_editor', 'Starting moveTrailToMission: index=' .. trailIndex .. ', mission=' .. missionName)

  local currentLevel = getCurrentLevelIdentifier()
  if not currentLevel then
    log('E', 'crawl_editor', 'No level currently loaded')
    return false
  end

  local missionsPath = "/gameplay/missions/" .. currentLevel .. "/crawl/"
  if not FS:directoryExists(missionsPath) then
    FS:directoryCreate(missionsPath)
  end

  local missionDir = missionsPath .. missionName .. "/"
  if not FS:directoryExists(missionDir) then
    FS:directoryCreate(missionDir)
  end

  local newTrailFile = missionDir .. missionName .. ".trail.json"
  if FS:fileExists(newTrailFile) then
    log('E', 'crawl_editor', 'Trail file already exists in mission: ' .. newTrailFile)
    return false
  end

  trail._isFromMission = true
  trail._missionName = missionName

  local levelCrawlDir = "/levels/" .. currentLevel .. "/crawls/"

  if trail.pathId then
    local pathFileName = missionName .. ".path.json"
    trail.pathId = levelCrawlDir .. pathFileName
  end

  if trail.boundaryId then
    local boundaryFileName = missionName .. ".boundary.json"
    trail.boundaryId = levelCrawlDir .. boundaryFileName
  end

  local success = gameplay_crawl_saveSystem.saveTrail(trail, newTrailFile)
  if not success then
    log('E', 'crawl_editor', 'Failed to save trail to mission directory')
    return false
  end

  FS:removeFile(trail._filePath)

  if trail.pathId then
    local path = gameplay_crawl_saveSystem.getPathById(trail.pathId)
    if path then
      path.isFromMission = false
      path._isFromMission = false
      path._missionName = nil
      gameplay_crawl_saveSystem.savePath(path, path._filePath)
    end
  end

  if trail.boundaryId then
    local boundary = gameplay_crawl_saveSystem.getBoundaryById(trail.boundaryId)
    if boundary then
      boundary.isFromMission = false
      boundary._isFromMission = false
      boundary._missionName = nil
      gameplay_crawl_saveSystem.saveBoundary(boundary, boundary._filePath)
    end
  end

  table.remove(allTrails, trailIndex)

  if selectedTrailIndex == trailIndex then
    selectedTrailIndex = 0
  elseif selectedTrailIndex > trailIndex then
    selectedTrailIndex = selectedTrailIndex - 1
  end

  loadAllObjects()

  log('D', 'crawl_editor', 'Successfully moved trail to mission: ' .. missionName)
  return true
end

local function moveTrailToLevel(trail)
  if not trail or not trail._isFromMission then
    log('E', 'crawl_editor', 'Trail is not from mission or does not exist')
    return false
  end

  local currentLevel = getCurrentLevelIdentifier()
  if not currentLevel then
    log('E', 'crawl_editor', 'No level currently loaded')
    return false
  end

  local levelCrawlDir = "/levels/" .. currentLevel .. "/crawls/"
  if not FS:directoryExists(levelCrawlDir) then
    FS:directoryCreate(levelCrawlDir)
  end

  local newTrailFile = levelCrawlDir .. trail._fileName .. ".trail.json"
  if FS:fileExists(newTrailFile) then
    log('E', 'crawl_editor', 'Trail file already exists in level: ' .. newTrailFile)
    return false
  end

  trail._isFromMission = false
  trail._missionName = nil

  if trail.pathId then
    local pathFileName = trail._fileName .. ".path.json"
    trail.pathId = levelCrawlDir .. pathFileName
  end

  if trail.boundaryId then
    local boundaryFileName = trail._fileName .. ".boundary.json"
    trail.boundaryId = levelCrawlDir .. boundaryFileName
  end

  local success = gameplay_crawl_saveSystem.saveTrail(trail, newTrailFile)
  if not success then
    log('E', 'crawl_editor', 'Failed to save trail to level directory')
    return false
  end

  FS:removeFile(trail._filePath)

  for i, missionTrail in ipairs(missionTrails) do
    if missionTrail == trail then
      table.remove(missionTrails, i)
      break
    end
  end

  table.insert(allTrails, trail)

  loadAllObjects()

  log('D', 'crawl_editor', 'Successfully moved trail to level: ' .. trail._fileName)
  return true
end

local function createAndSaveObject(type, filePath)
  local success = false
  local newObject = nil

  if not type or not filePath then
    log('E', 'crawl_editor', 'Invalid type or filePath provided to createAndSaveObject')
    return false
  end

  if type == "trail" then
    newObject = trails:getNewTrail()
    if newObject then
      success = gameplay_crawl_saveSystem.saveTrail(newObject, filePath)
    end
  elseif type == "path" then
    newObject = paths:getNewPath()
    if newObject then
      success = gameplay_crawl_saveSystem.savePath(newObject, filePath)
    end
  elseif type == "boundary" then
    newObject = boundaries:getNewBoundary()
    if newObject then
      success = gameplay_crawl_saveSystem.saveBoundary(newObject, filePath)
    end
  elseif type == "startingPosition" then
    newObject = startingPositions:getNewStartingPosition()
    if newObject then
      success = gameplay_crawl_saveSystem.saveStartingPosition(newObject, filePath)
    end
  else
    log('E', 'crawl_editor', string.format('Unknown object type: %s', type))
    return false
  end

  if success and newObject then
    loadAllObjects()

    if type == "trail" then
      for i, trail in ipairs(allTrails) do
        if trail._filePath == filePath then
          selectedTrailIndex = i
          currentTab = "trails"
          editor.selectEditMode(editor.editModes.trailEditMode)
          trails:setTrail(trail)
          break
        end
      end
    elseif type == "path" then
      for i, path in ipairs(allPaths) do
        if path._filePath == filePath then
          selectedPathIndex = i
          currentTab = "paths"
          editor.selectEditMode(editor.editModes.pathEditMode)
          paths:setPath(path)
          break
        end
      end
    elseif type == "boundary" then
      for i, boundary in ipairs(allBoundaries) do
        if boundary._filePath == filePath then
          selectedBoundaryIndex = i
          currentTab = "boundaries"
          editor.selectEditMode(editor.editModes.boundaryEditMode)
          boundaries:setBoundary(boundary)
          break
        end
      end
    elseif type == "startingPosition" then
      for i, startingPosition in ipairs(allStartingPositions) do
        if startingPosition._filePath == filePath then
          selectedStartingPositionIndex = i
          currentTab = "startingPositions"
          editor.selectEditMode(editor.editModes.startingPositionEditMode)
          startingPositions:setStartingPosition(startingPosition)
          break
        end
      end
    end

    log('D', 'crawl_editor', string.format('Successfully created and saved new %s to: %s', type, filePath))
  else
    log('E', 'crawl_editor', string.format('Failed to create and save new %s to: %s', type, filePath))
  end

  return success
end

local function showFileSelectionDialog(type)
  local fileSuffix = {}
  if type == "trail" then
    fileSuffix = {{"Trail Files", ".trail.json"}}
  elseif type == "path" then
    fileSuffix = {{"Path Files", ".path.json"}}
  elseif type == "boundary" then
    fileSuffix = {{"Boundary Files", ".boundary.json"}}
  elseif type == "startingPosition" then
    fileSuffix = {{"Starting Position Files", ".startingPosition.json"}}
  end

  local currentLevel = getCurrentLevelIdentifier()
  if not currentLevel then
    log('E', 'crawl_editor', 'No level currently loaded, cannot save file')
    return
  end

  local currentFileDir = "levels/" .. currentLevel .. "/crawls/"
  extensions.editor_fileDialog.saveFile(
    function(data)
      createAndSaveObject(type, data.filepath)
    end,
    fileSuffix,
    false,
    currentFileDir
  )
end

local function show()
  editor.clearObjectSelection()
  editor.showWindow(toolWindowName)
  local currentLevel = getCurrentLevelIdentifier()
  if currentLevel then
    currentFileDir = "levels/" .. currentLevel .. "/crawls/"
  end
  -- If no level loaded, keep currentFileDir at its default value
end

local function onPathEditModeActivate()
  editor.clearObjectSelection()
  local selectedPath = getSelectedPath()
  if selectedPath then
    paths:setPath(selectedPath)
  end
end

local function onPathEditModeDeactivate()
  paths:setPath(nil)
  paths:selectPathnode(nil)
  editor.clearObjectSelection()
end

local function onPathEditModeUpdate()
  local selectedPath = getSelectedPath()
  if not selectedPath then
    return
  end
  input.updateMouseInfo()
  mouseInfo = input.getMouseInfo()
  paths:draw(mouseInfo)
end

local function drawPathnodesAlways()
  local selectedPath = getSelectedPath()
  if not selectedPath then
    return
  end

  paths:setPath(selectedPath)
  paths:drawPathnodeSelectionIndicators(mouseInfo)
end

local function onBoundaryEditModeActivate()
  editor.clearObjectSelection()
  local selectedBoundary = getSelectedBoundary()
  if selectedBoundary then
    boundaries:setBoundary(selectedBoundary)
  end
end

local function onBoundaryEditModeDeactivate()
  boundaries:setBoundary(nil)
  editor.clearObjectSelection()
end

local function onBoundaryEditModeUpdate()
  local selectedBoundary = getSelectedBoundary()
  if not selectedBoundary then
    return
  end
  input.updateMouseInfo()
  mouseInfo = input.getMouseInfo()
  boundaries:draw(mouseInfo)
end

local function onStartingPositionEditModeActivate()
  editor.clearObjectSelection()
  local selectedStartingPosition = getSelectedStartingPosition()
  if selectedStartingPosition then
    startingPositions:setStartingPosition(selectedStartingPosition)
  end
end

local function onStartingPositionEditModeDeactivate()
  startingPositions:setStartingPosition(nil)
  editor.clearObjectSelection()
end

local function onStartingPositionEditModeUpdate()
  local selectedStartingPosition = getSelectedStartingPosition()
  if not selectedStartingPosition then
    return
  end
  input.updateMouseInfo()
  mouseInfo = input.getMouseInfo()
  startingPositions:draw(mouseInfo)
end

local function onTrailEditModeUpdate()
  local selectedTrail = getSelectedTrail()
  if not selectedTrail then
    return
  end
  input.updateMouseInfo()
  mouseInfo = input.getMouseInfo()
  trails:draw(mouseInfo)
end

local function onTrailEditModeActivate()
  local selectedTrail = getSelectedTrail()
  if selectedTrail then
    trails:setTrail(selectedTrail)
  end
end

local function onTrailEditModeDeactivate()
  trails:clearSelection()
end

local function drawBoundariesAlways()
  local selectedBoundary = getSelectedBoundary()
  if not selectedBoundary then
    return
  end

  boundaries:setBoundary(selectedBoundary)
  -- Draw the boundary fence/planes whenever it is selected (parity with path always-draw).
  if selectedBoundary.drawDebug then
    selectedBoundary:drawDebug()
  end
end

local function drawStartingPositionsAlways()
  local selectedStartingPosition = getSelectedStartingPosition()
  if not selectedStartingPosition then
    return
  end

  startingPositions:setStartingPosition(selectedStartingPosition)
  startingPositions:drawStartingPositionIndicators(mouseInfo)
end

local function updateCurrentTab()
  if selectedTrailIndex > 0 then
    currentTab = "trails"
  elseif selectedPathIndex > 0 then
    currentTab = "paths"
  elseif selectedBoundaryIndex > 0 then
    currentTab = "boundaries"
  elseif selectedStartingPositionIndex > 0 then
    currentTab = "startingPositions"
  else
    currentTab = "none"
  end
end

local crawlEditorDataLoaded = false

local function onEditorInitialized()
  editor.registerWindow(toolWindowName, im.ImVec2(1800,900))
  editor.addWindowMenuItem("Crawl Data Editor", function() show() end, {groupMenuName="Gameplay"})

  if crawlData == nil then
    crawlData = getNewCrawlData()
  end

  trails:setCurrentTab("paths")

  editor.editModes.pathEditMode = {
    displayName = pathEditModeName,
    onUpdate = onPathEditModeUpdate,
    onActivate = onPathEditModeActivate,
    onDeactivate = onPathEditModeDeactivate,
    auxShortcuts = {},
    icon = editor.icons.tb_path,
    iconTooltip = "Pathnode Editor",
    hideObjectIcons = true
  }

  editor.editModes.pathEditMode.auxShortcuts[bit.bor(editor.AuxControl_LMB, editor.AuxControl_Shift)] = "Create new pathnode"

  editor.editModes.boundaryEditMode = {
    displayName = boundaryEditModeName,
    onUpdate = onBoundaryEditModeUpdate,
    onActivate = onBoundaryEditModeActivate,
    onDeactivate = onBoundaryEditModeDeactivate,
    auxShortcuts = {},
    icon = editor.icons.tb_zone,
    iconTooltip = "Boundary Editor",
    hideObjectIcons = true
  }

  editor.editModes.boundaryEditMode.auxShortcuts[bit.bor(editor.AuxControl_LMB, editor.AuxControl_Shift)] = "Add boundary vertex"
  editor.editModes.boundaryEditMode.auxShortcuts[bit.bor(editor.AuxControl_LMB, editor.AuxControl_Alt)] = "Insert vertex between existing"
  editor.editModes.boundaryEditMode.auxShortcuts[bit.bor(editor.AuxControl_LMB, editor.AuxControl_Ctrl)] = "Select multiple vertices"

  editor.editModes.startingPositionEditMode = {
    displayName = "Edit Starting Position",
    onUpdate = onStartingPositionEditModeUpdate,
    onActivate = onStartingPositionEditModeActivate,
    onDeactivate = onStartingPositionEditModeDeactivate,
    auxShortcuts = {},
    icon = editor.icons.tb_path,
    iconTooltip = "Starting Position Editor",
    hideObjectIcons = true
  }

  editor.editModes.startingPositionEditMode.auxShortcuts[bit.bor(editor.AuxControl_LMB)] = "Select starting position"

  editor.editModes.trailEditMode = {
    displayName = trailEditModeName,
    onUpdate = onTrailEditModeUpdate,
    onActivate = onTrailEditModeActivate,
    onDeactivate = onTrailEditModeDeactivate,
    auxShortcuts = {},
    icon = editor.icons.tb_path,
    iconTooltip = "Trail Editor",
    hideObjectIcons = true
  }

  editor.editModes.trailEditMode.auxShortcuts[bit.bor(editor.AuxControl_LMB)] = "Select trail position"
end

local function onSerialize()
  local ret = {
    currentFileDir = currentFileDir,
    currentFileName = currentFileName,
    crawlData = crawlData,
    currentTab = currentTab,
    selectedTrailIndex = selectedTrailIndex,
    selectedPathIndex = selectedPathIndex,
    selectedBoundaryIndex = selectedBoundaryIndex,
    selectedStartingPositionIndex = selectedStartingPositionIndex
  }
  return ret
end

local function onDeserialized(data)
  if data then
    currentFileDir = data.currentFileDir or currentFileDir
    currentFileName = data.currentFileName
    crawlData = data.crawlData or crawlData
    currentTab = data.currentTab or currentTab
    selectedTrailIndex = data.selectedTrailIndex or -1
    selectedPathIndex = data.selectedPathIndex or -1
    selectedBoundaryIndex = data.selectedBoundaryIndex or -1
    selectedStartingPositionIndex = data.selectedStartingPositionIndex or -1
  end
end

local function onEditorGui()
  if not crawlData then return end

  -- Refresh mouse info every frame so the always-draw overlays (which need camPos for
  -- distance scaling and picking) are never stale, even when no edit mode is active.
  input.updateMouseInfo()
  mouseInfo = input.getMouseInfo()

  drawPathnodesAlways()
  drawBoundariesAlways()
  drawStartingPositionsAlways()

  if editor.beginWindow(toolWindowName, toolWindowName, im.flags(im.WindowFlags_MenuBar)) then
    if not crawlEditorDataLoaded then
      crawlEditorDataLoaded = true
      if getCurrentLevelIdentifier() then
        loadAllObjects()
        updateCurrentTab()
      end
    end
    if im.BeginMenuBar() then
      if im.BeginMenu("File") then
        if im.MenuItem1("Save All") then
          local savedCount = 0
          local movedCount = 0

          for i = #allTrails, 1, -1 do
            local trail = allTrails[i]
            -- Only save if dirty (has changes) or needs to be moved
            if trail.isFromMission and not trail._isFromMission then
              local success = moveTrailToMission(i)
              if success then
                movedCount = movedCount + 1
                log('D', 'crawl_editor', string.format('Moved trail (%s) to mission', trail._fileName or 'unnamed'))
              end
            elseif trail._dirty then
              if gameplay_crawl_saveSystem.saveTrail(trail, trail._filePath) then
                savedCount = savedCount + 1
                trail._dirty = false
                log('D', 'crawl_editor', string.format('Marked trail (%s) as clean after Save All', trail._fileName or 'unnamed'))
              end
            end
          end

          for i = #missionTrails, 1, -1 do
            local trail = missionTrails[i]
            -- Only save if dirty (has changes) or needs to be moved
            if not trail.isFromMission and trail._isFromMission then
              local success = moveTrailToLevel(trail)
              if success then
                movedCount = movedCount + 1
                log('D', 'crawl_editor', string.format('Moved trail (%s) to level', trail._fileName or 'unnamed'))
              end
            elseif trail._dirty then
              if gameplay_crawl_saveSystem.saveTrail(trail, trail._filePath) then
                savedCount = savedCount + 1
                trail._dirty = false
                log('D', 'crawl_editor', string.format('Marked mission trail (%s) as clean after Save All', trail._fileName or 'unnamed'))
              end
            end
          end


          for _, path in ipairs(allPaths) do
            if path._dirty then
              if gameplay_crawl_saveSystem.savePath(path, path._filePath) then
                savedCount = savedCount + 1
                path._dirty = false
                log('D', 'crawl_editor', string.format('Marked path (%s) as clean after Save All', path._fileName or 'unnamed'))
              end
            end
          end

          for _, path in ipairs(missionPaths) do
            if path._dirty then
              if gameplay_crawl_saveSystem.savePath(path, path._filePath) then
                savedCount = savedCount + 1
                path._dirty = false
                log('D', 'crawl_editor', string.format('Marked mission path (%s) as clean after Save All', path._fileName or 'unnamed'))
              end
            end
          end

          for _, boundary in ipairs(allBoundaries) do
            if boundary._dirty then
              if gameplay_crawl_saveSystem.saveBoundary(boundary, boundary._filePath) then
                savedCount = savedCount + 1
                boundary._dirty = false
                log('D', 'crawl_editor', string.format('Marked boundary (%s) as clean after Save All', boundary._fileName or 'unnamed'))
              end
            end
          end

          for _, boundary in ipairs(missionBoundaries) do
            if boundary._dirty then
              if gameplay_crawl_saveSystem.saveBoundary(boundary, boundary._filePath) then
                savedCount = savedCount + 1
                boundary._dirty = false
                log('D', 'crawl_editor', string.format('Marked mission boundary (%s) as clean after Save All', boundary._fileName or 'unnamed'))
              end
            end
          end

          for _, startingPosition in ipairs(allStartingPositions) do
            if startingPosition._dirty then
              if gameplay_crawl_saveSystem.saveStartingPosition(startingPosition, startingPosition._filePath) then
                savedCount = savedCount + 1
                startingPosition._dirty = false
                log('D', 'crawl_editor', string.format('Marked starting position (%s) as clean after Save All', startingPosition._fileName or 'unnamed'))
              end
            end
          end

          log('D', 'crawl_editor', 'Saved ' .. savedCount .. ' objects, moved ' .. movedCount .. ' trails to missions')
        end

        if im.MenuItem1("Reload All") then
          loadAllObjects()
          log('D', 'crawl_editor', 'Reloaded all objects')
        end

        im.Separator()

        if im.MenuItem1("Clear Cache") then
          gameplay_crawl_saveSystem.clearCache()
          log('D', 'crawl_editor', 'Cleared save system cache')
        end

        im.EndMenu()
      end

      if im.BeginMenu("View") then
        if im.MenuItem1("Refresh Lists") then
          loadAllObjects()
          log('D', 'crawl_editor', 'Refreshed object lists')
        end
        if gameplay_crawl_utils and gameplay_crawl_utils.toggleDebugDraw then
          local overlayOn = gameplay_crawl_utils.isDebugDrawEnabled and gameplay_crawl_utils.isDebugDrawEnabled()
          if im.MenuItem1("Runtime Debug Overlay", nil, overlayOn) then
            gameplay_crawl_utils.toggleDebugDraw()
          end
        end
        if gameplay_crawl_debug and gameplay_crawl_debug.setEnableDebugWindow then
          local windowOn = gameplay_crawl_debug.getEnableDebugWindow and gameplay_crawl_debug.getEnableDebugWindow()
          if im.MenuItem1("Runtime Debug Window", nil, windowOn) then
            gameplay_crawl_debug.setEnableDebugWindow(not windowOn)
          end
        end
        im.EndMenu()
      end

      if im.BeginMenu("Tools") then
        if im.MenuItem1("Port Mission to New System") then
          log('D', 'crawl_editor', 'Port Mission menu item clicked')
          missionPortTool.openPortingDialog()
        end
        im.EndMenu()
      end

      im.EndMenuBar()
    end

    im.Text("Current tab: " .. currentTab)
    im.Separator()
    if im.BeginChild1("LeftPanel", im.ImVec2(im.GetWindowWidth() * 0.4, 0), true) then

      im.Separator()
      im.TextColored(im.ImVec4(0.8, 0.6, 0.2, 1.0), "Trails")
      im.SameLine()
      if im.Button("Add Trail") then
        showFileSelectionDialog("trail")
      end
      for idx, trail in ipairs(allTrails) do
        im.PushID1("trail_" .. idx)

        local displayName = trail._fileName
        if trail._dirty then
          displayName = "*** " .. displayName .. " ***"
          im.PushStyleColor2(im.Col_Text, unsavedColor)
        end

        if im.Selectable1(displayName..'##'..trail._filePath, selectedTrailIndex == idx) then
          selectedTrailIndex = idx
          selectOnly("trail")
          currentTab = "trails"
          editor.selectEditMode(editor.editModes.trailEditMode)
        end

        if trail._dirty then im.PopStyleColor() end
        im.PopID()
      end

      for idx, trail in ipairs(missionTrails) do
        im.PushID1("mission_trail_" .. idx)

        local displayName = "[MISSION] " .. (trail._missionName or trail._fileName)
        if trail._dirty then
          displayName = "*** " .. displayName .. " ***"
          im.PushStyleColor2(im.Col_Text, unsavedColor)
        end

        if im.Selectable1(displayName..'##'..trail._filePath, selectedTrailIndex == idx + #allTrails) then
          selectedTrailIndex = idx + #allTrails
          selectOnly("trail")
          currentTab = "trails"
          editor.selectEditMode(editor.editModes.trailEditMode)
        end

        if trail._dirty then im.PopStyleColor() end
        im.PopID()
      end

      im.Separator()
      im.TextColored(im.ImVec4(0.8, 0.6, 0.2, 1.0), "Paths")
      im.SameLine()
      if im.Button("Add Path") then
        showFileSelectionDialog("path")
      end
      for idx, path in ipairs(allPaths) do
        im.PushID1("path_" .. idx)

        local displayName = path._fileName
        if path._dirty then
          displayName = "*** " .. displayName .. " ***"
          im.PushStyleColor2(im.Col_Text, unsavedColor)
        end

        if im.Selectable1(displayName..'##'..path._filePath, selectedPathIndex == idx) then
          selectedPathIndex = idx
          selectOnly("path")
          currentTab = "paths"
          editor.selectEditMode(editor.editModes.pathEditMode)
        end

        if path._dirty then im.PopStyleColor() end
        im.PopID()
      end

      for idx, path in ipairs(missionPaths) do
        im.PushID1("mission_path_" .. idx)

        local displayName = "[MISSION] " .. (path._missionName or path._fileName)
        if path._dirty then
          displayName = "*** " .. displayName .. " ***"
          im.PushStyleColor2(im.Col_Text, unsavedColor)
        end

        if im.Selectable1(displayName..'##'..path._filePath, selectedPathIndex == idx + #allPaths) then
          selectedPathIndex = idx + #allPaths
          selectOnly("path")
          currentTab = "paths"
          editor.selectEditMode(editor.editModes.pathEditMode)
        end

        if path._dirty then im.PopStyleColor() end
        im.PopID()
      end

      im.Separator()
      im.TextColored(im.ImVec4(0.8, 0.6, 0.2, 1.0), "Boundaries")
      im.SameLine()
      if im.Button("Add Boundary") then
        showFileSelectionDialog("boundary")
      end
      for idx, boundary in ipairs(allBoundaries) do
        im.PushID1("boundary_" .. idx)

        local displayName = boundary._fileName
        if boundary._dirty then
          displayName = "*** " .. displayName .. " ***"
          im.PushStyleColor2(im.Col_Text, unsavedColor)
        end

        if im.Selectable1(displayName..'##'..boundary._filePath, selectedBoundaryIndex == idx) then
          selectedBoundaryIndex = idx
          selectOnly("boundary")
          currentTab = "boundaries"
          editor.selectEditMode(editor.editModes.boundaryEditMode)
        end

        if boundary._dirty then im.PopStyleColor() end
        im.PopID()
      end

      for idx, boundary in ipairs(missionBoundaries) do
        im.PushID1("mission_boundary_" .. idx)

        local displayName = "[MISSION] " .. (boundary._missionName or boundary._fileName)
        if boundary._dirty then
          displayName = "*** " .. displayName .. " ***"
          im.PushStyleColor2(im.Col_Text, unsavedColor)
        end

        if im.Selectable1(displayName..'##'..boundary._filePath, selectedBoundaryIndex == idx + #allBoundaries) then
          selectedBoundaryIndex = idx + #allBoundaries
          selectOnly("boundary")
          currentTab = "boundaries"
          editor.selectEditMode(editor.editModes.boundaryEditMode)
        end

        if boundary._dirty then im.PopStyleColor() end
        im.PopID()
      end

      im.Separator()
      im.TextColored(im.ImVec4(0.8, 0.6, 0.2, 1.0), "Starting Positions")
      im.SameLine()
      if im.Button("Add Starting Position") then
        showFileSelectionDialog("startingPosition")
      end
      for idx, startingPosition in ipairs(allStartingPositions) do
        im.PushID1("starting_position_" .. idx)

        local displayName = startingPosition._fileName
        if startingPosition._dirty then
          displayName = "*** " .. displayName .. " ***"
          im.PushStyleColor2(im.Col_Text, im.ImVec4(1.0, 0.0, 0.0, 1.0))
        end

        if im.Selectable1(displayName..'##'..startingPosition._filePath, selectedStartingPositionIndex == idx) then
          selectedStartingPositionIndex = idx
          selectOnly("startingPosition")
          currentTab = "startingPositions"
          editor.selectEditMode(editor.editModes.startingPositionEditMode)
        end

        if startingPosition._dirty then im.PopStyleColor() end
        im.PopID()
      end

    end
    im.EndChild()

    im.SameLine()

    if im.BeginChild1("RightPanel", im.ImVec2(0, 0), true) then
      im.Text("Details")
      im.SameLine()
      if im.Button("Save") then
        if currentTab == "trails" and selectedTrailIndex > 0 then
          local selectedTrail = getSelectedTrail()
          if selectedTrail then
            if selectedTrail.isFromMission and not selectedTrail._isFromMission then
              local success = moveTrailToMission(selectedTrailIndex)
              if success then
                log('D', logTag, 'Trail moved to mission: ' .. (selectedTrail._fileName or 'unnamed'))
              else
                log('W', logTag, 'Failed to move trail to mission')
              end
            elseif not selectedTrail.isFromMission and selectedTrail._isFromMission then
              local success = moveTrailToLevel(selectedTrail)
              if success then
                log('D', logTag, 'Trail moved to level: ' .. (selectedTrail._fileName or 'unnamed'))
              else
                log('W', logTag, 'Failed to move trail to level')
              end
            else
              if gameplay_crawl_saveSystem.saveTrail(selectedTrail, selectedTrail._filePath) then
                selectedTrail._dirty = false
                log('D', logTag, 'Marked trail ' .. selectedTrailIndex .. ' (' .. (selectedTrail._fileName or 'unnamed') .. ') as clean after save')
              end
            end
          end
        end
        if currentTab == "paths" and selectedPathIndex > 0 then
          local selectedPath = getSelectedPath()
          if selectedPath then
            if gameplay_crawl_saveSystem.savePath(selectedPath, selectedPath._filePath) then
              selectedPath._dirty = false
              log('D', logTag, 'Marked path ' .. selectedPathIndex .. ' (' .. (selectedPath._fileName or 'unnamed') .. ') as clean after save')
            end
          end
        end
        if currentTab == "boundaries" and selectedBoundaryIndex > 0 then
          local selectedBoundary = getSelectedBoundary()
          if selectedBoundary then
            if gameplay_crawl_saveSystem.saveBoundary(selectedBoundary, selectedBoundary._filePath) then
              selectedBoundary._dirty = false
              log('D', logTag, 'Marked boundary ' .. selectedBoundaryIndex .. ' (' .. (selectedBoundary._fileName or 'unnamed') .. ') as clean after save')
            end
          end
        end
        if currentTab == "startingPositions" and selectedStartingPositionIndex > 0 then
          local selectedStartingPosition = allStartingPositions[selectedStartingPositionIndex]
          if selectedStartingPosition then
            if gameplay_crawl_saveSystem.saveStartingPosition(selectedStartingPosition, selectedStartingPosition._filePath) then
              selectedStartingPosition._dirty = false
              log('D', logTag, 'Marked starting position ' .. selectedStartingPositionIndex .. ' (' .. (selectedStartingPosition._fileName or 'unnamed') .. ') as clean after save')
            end
          end
        end
      end

      if currentTab == "trails" and selectedTrailIndex > 0 then
        im.SameLine()
        im.PushStyleColor2(im.Col_Button, im.ImVec4(0.8, 0.2, 0.2, 1.0))
        im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(0.9, 0.3, 0.3, 1.0))
        im.PushStyleColor2(im.Col_ButtonActive, im.ImVec4(0.7, 0.1, 0.1, 1.0))
        if im.Button("Delete Trail") then
          local selectedTrail = getSelectedTrail()
          if selectedTrail then
            if selectedTrail._filePath and FS:fileExists(selectedTrail._filePath) then
              FS:removeFile(selectedTrail._filePath)
              log('D', 'crawl_editor', 'Deleted trail file: ' .. selectedTrail._filePath)
            end

            selectedTrailIndex = 0
            currentTab = "none"
            trails:clearSelection()
            loadAllObjects()
          end
        end
        im.PopStyleColor()
        im.PopStyleColor()
        im.PopStyleColor()
      elseif currentTab == "paths" and selectedPathIndex > 0 then
        im.SameLine()
        im.PushStyleColor2(im.Col_Button, im.ImVec4(0.8, 0.2, 0.2, 1.0))
        im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(0.9, 0.3, 0.3, 1.0))
        im.PushStyleColor2(im.Col_ButtonActive, im.ImVec4(0.7, 0.1, 0.1, 1.0))
        if im.Button("Delete Path") then
          local selectedPath = getSelectedPath()
          if selectedPath then
            if selectedPath._filePath and FS:fileExists(selectedPath._filePath) then
              FS:removeFile(selectedPath._filePath)
              log('D', 'crawl_editor', 'Deleted path file: ' .. selectedPath._filePath)
            end

            for _, trail in ipairs(allTrails) do
              if trail.pathId == selectedPath._filePath then
                trail.pathId = nil
                trail.pathReversed = false
                trail._dirty = true
              end
            end

            selectedPathIndex = 0
            currentTab = "none"
            paths:setPath(nil)
            loadAllObjects()
          end
        end
        im.PopStyleColor()
        im.PopStyleColor()
        im.PopStyleColor()
      elseif currentTab == "boundaries" and selectedBoundaryIndex > 0 then
        im.SameLine()
        im.PushStyleColor2(im.Col_Button, im.ImVec4(0.8, 0.2, 0.2, 1.0))
        im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(0.9, 0.3, 0.3, 1.0))
        im.PushStyleColor2(im.Col_ButtonActive, im.ImVec4(0.7, 0.1, 0.1, 1.0))
        if im.Button("Delete Boundary") then
          local selectedBoundary = getSelectedBoundary()
          if selectedBoundary then
            if selectedBoundary._filePath and FS:fileExists(selectedBoundary._filePath) then
              FS:removeFile(selectedBoundary._filePath)
              log('D', 'crawl_editor', 'Deleted boundary file: ' .. selectedBoundary._filePath)
            end

            for _, trail in ipairs(allTrails) do
              if trail.boundaryId == selectedBoundary._filePath then
                trail.boundaryId = nil
                trail._dirty = true
              end
            end

            selectedBoundaryIndex = 0
            currentTab = "none"
            boundaries:setBoundary(nil)
            loadAllObjects()
          end
        end
        im.PopStyleColor()
        im.PopStyleColor()
        im.PopStyleColor()
      elseif currentTab == "startingPositions" and selectedStartingPositionIndex > 0 then
        im.SameLine()
        im.PushStyleColor2(im.Col_Button, im.ImVec4(0.8, 0.2, 0.2, 1.0))
        im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(0.9, 0.3, 0.3, 1.0))
        im.PushStyleColor2(im.Col_ButtonActive, im.ImVec4(0.7, 0.1, 0.1, 1.0))
        if im.Button("Delete Starting Position") then
          local selectedStartingPosition = getSelectedStartingPosition()
          if selectedStartingPosition then
            if selectedStartingPosition._filePath and FS:fileExists(selectedStartingPosition._filePath) then
              FS:removeFile(selectedStartingPosition._filePath)
              log('D', 'crawl_editor', 'Deleted starting position file: ' .. selectedStartingPosition._filePath)
            end

            for _, trail in ipairs(allTrails) do
              if trail.startingPositionId == selectedStartingPosition._filePath then
                trail.startingPositionId = nil
                trail._dirty = true
              end
            end

            selectedStartingPositionIndex = 0
            currentTab = "none"
            startingPositions:setStartingPosition(nil)
            loadAllObjects()
          end
        end
        im.PopStyleColor()
        im.PopStyleColor()
        im.PopStyleColor()
      end

      im.Separator()

      if currentTab == "trails" and selectedTrailIndex > 0 then
        local selectedTrail = getSelectedTrail()
        if selectedTrail then
          trails:drawTrailDetail(selectedTrail)
        end
      elseif currentTab == "paths" and selectedPathIndex > 0 then
        local selectedPath = getSelectedPath()
        if selectedPath then
          paths:drawPathDetail(selectedPath)
        end
      elseif currentTab == "boundaries" and selectedBoundaryIndex > 0 then
        local selectedBoundary = getSelectedBoundary()
        if selectedBoundary then
          boundaries:drawBoundaryDetail(selectedBoundary)
        end
      elseif currentTab == "startingPositions" and selectedStartingPositionIndex > 0 then
        local selectedStartingPosition = allStartingPositions[selectedStartingPositionIndex]
        if selectedStartingPosition then
          startingPositions:drawStartingPositionDetail(selectedStartingPosition)
        end
      else
        im.Text("Select a trail, path, boundary, or starting position to view details.")
      end

    end
    im.EndChild()

  end
  editor.endWindow()


  -- Show mission porting dialog if needed
  missionPortTool.showPortingDialog()
end

M.getAllTrails = function() return allTrails end
M.getAllMissionTrails = function() return missionTrails end
M.getAllPaths = function() return allPaths end
M.getAllMissionPaths = function() return missionPaths end
M.getAllBoundaries = function() return allBoundaries end
M.getAllMissionBoundaries = function() return missionBoundaries end
M.getAllStartingPositions = function() return allStartingPositions end
M.getSelectedTrailIndex = function() return selectedTrailIndex end
M.getSelectedPathIndex = function() return selectedPathIndex end
M.getSelectedBoundaryIndex = function() return selectedBoundaryIndex end
M.getSelectedStartingPositionIndex = function() return selectedStartingPositionIndex end
M.setSelectedTrailIndex = function(index) selectedTrailIndex = index end
M.setSelectedPathIndex = function(index) selectedPathIndex = index end
M.setSelectedBoundaryIndex = function(index) selectedBoundaryIndex = index end
M.setSelectedStartingPositionIndex = function(index) selectedStartingPositionIndex = index end
M.getSelectedTrail = getSelectedTrail
M.getSelectedPath = getSelectedPath
M.getSelectedBoundary = getSelectedBoundary
M.getSelectedStartingPosition = getSelectedStartingPosition
M.renameObjectFile = renameObjectFile
M.markAsDirty = markAsDirty
M.onEditorInitialized = onEditorInitialized
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onEditorGui = onEditorGui
M.loadAllObjects = loadAllObjects
M.moveTrailToLevel = moveTrailToLevel

return M
