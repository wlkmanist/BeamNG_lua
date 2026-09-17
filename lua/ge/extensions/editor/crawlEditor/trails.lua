-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
local im = ui_imgui
local ffi = require('ffi')

local lastTrail = nil
local editEnded = im.BoolPtr(false)
local missingRefColor = im.ImVec4(1.0, 0.3, 0.1, 1.0)

-- Combine a level-scoped list with an optional mission-scoped list so trail
-- reference dropdowns can point at both level and mission components.
local function mergedList(levelList, missionGetter)
  local out = {}
  if levelList then
    for _, v in ipairs(levelList) do out[#out + 1] = v end
  end
  if missionGetter then
    local m = missionGetter()
    if m then
      for _, v in ipairs(m) do out[#out + 1] = v end
    end
  end
  return out
end

local function setFieldUndo(data)
  local trail = data.trail
  if trail then
    trail[data.field] = data.old
  end
end

local function setFieldRedo(data)
  local trail = data.trail
  if trail then
    trail[data.field] = data.new
  end
end

local function teleportCameraTo(pos)
  if not pos then return end
  core_camera.setPosition(0, pos + vec3(0, 0, 15))
end

local function markTrailAsDirty(trail)
  if editor_crawlEditor and editor_crawlEditor.markAsDirty then
    local allTrails = editor_crawlEditor.getAllTrails()
    local missionTrails = editor_crawlEditor.getAllMissionTrails()

    for i, t in ipairs(allTrails) do
      if t == trail then
        editor_crawlEditor.markAsDirty("trail", i)
        return
      end
    end

    for i, t in ipairs(missionTrails) do
      if t == trail then
        editor_crawlEditor.markAsDirty("trail", i + #allTrails)
        return
      end
    end
  end
end



function C:init()
  self.currentTab = "paths"
  self.trail = nil
  self.snapToTerrain = true
end

function C:getPrefabFiles()
  local prefabFiles = {}
  local currentLevel = getCurrentLevelIdentifier()

  if currentLevel then
    -- Search in the current level's crawls directory
    local crawlsPath = '/levels/' .. currentLevel .. '/crawls/'
    local crawlsFiles = FS:findFiles(crawlsPath, "*.prefab.json", 1, false, true)
    for _, file in ipairs(crawlsFiles) do
      table.insert(prefabFiles, file)
    end

  end

  return prefabFiles
end


function C:drawTrailsList(allTrails, selection)
  if im.Button("Add Trail") then
    local newTrail = self:getNewTrail()
    table.insert(allTrails, newTrail)
    selection.index = #allTrails
  end

  for i, trail in ipairs(allTrails) do
    local isSelected = (i == selection.index)
    local displayName = trail.name or "Unnamed Trail"

    if im.Selectable1(displayName, isSelected) then
      if selection.index == i then
        selection.index = -1
      end
      selection.index = i
      selection.clicked = true
    end

    -- Right-click context menu
    if im.BeginPopupContextItem("trail_context_" .. i) then
      if im.MenuItem1("Delete") then
        local trail = allTrails[i]
        if trail then
          -- Delete the file from disk
          if trail._filePath and FS:fileExists(trail._filePath) then
            FS:removeFile(trail._filePath)
            log('D', 'crawl_editor', 'Deleted trail file: ' .. trail._filePath)
          end
        end
        table.remove(allTrails, i)
        if selection.index >= i then
          selection.index = selection.index - 1
        end
      end
      im.EndPopup()
    end
  end

  if #allTrails == 0 then
    im.Text("No trails available")
  end
end
function C:setFields(trail)
  if not trail then return end
  self.name = im.ArrayChar(256, trail.name or "")
  self.fileName = im.ArrayChar(256, trail._fileName or "")
  self.description = im.ArrayChar(1024, trail.description or "")
  self.rules = im.ArrayChar(1024, (trail.rules and trail.rules.description) or "")
  self.pathReversed = im.BoolPtr(trail.pathReversed or false)
  self.thumbnail = im.ArrayChar(512, trail.thumbnail or "")
  self.preview = im.ArrayChar(512, trail.preview or "")
  self.isFromMission = im.BoolPtr(trail.isFromMission or false)
  self.missionName = im.ArrayChar(256, trail._fileName or "")
end
function C:drawTrailDetail(trail)
  if not trail then return end

  if lastTrail ~= trail then
    self:setFields(trail)
    lastTrail = trail
  end

  im.Text("Trail Details")
  im.SameLine()
  if im.Button("Goto") then
    local startingPos = trail.startingPositionId and trail.startingPositionId ~= "" and
      gameplay_crawl_saveSystem and gameplay_crawl_saveSystem.getStartingPositionById(trail.startingPositionId)
    if startingPos and startingPos.transform then
      teleportCameraTo(startingPos.transform.position)
    else
      local allPaths = editor_crawlEditor and editor_crawlEditor.getAllPaths and editor_crawlEditor.getAllPaths() or {}
      for _, p in ipairs(allPaths) do
        if p._filePath == trail.pathId and p.nodes and p.nodes[1] then
          teleportCameraTo(p.nodes[1].pos)
          break
        end
      end
    end
  end
  im.SameLine()
  -- Quick-test the trail in freeroam without leaving the editor.
  if im.Button("Test From Start") then
    if gameplay_crawl_general and gameplay_crawl_general.startCrawlFreeroam then
      local veh = be:getPlayerVehicle(0)
      if veh then
        gameplay_crawl_general.startCrawlFreeroam(trail, veh)
      else
        log('W', 'crawl_editor', 'Cannot test crawl: no player vehicle')
      end
    end
  end
  im.Separator()

  -- Name
  im.Text("Name")
  editEnded[0] = false
  editor.uiInputText("##TrailName", self.name, nil, nil, nil, nil, editEnded)
  if editEnded[0] then
    editor.history:commitAction("Change Trail Name",
      {trail = trail, old = trail.name, new = ffi.string(self.name), field = 'name'},
      setFieldUndo, setFieldRedo)
    markTrailAsDirty(trail)
  end

  -- File Name (rename functionality)
  im.Separator()
  im.Text("File Name")
  im.SameLine()
  if im.Button("Rename") then
    local newFileName = ffi.string(self.fileName)
    if newFileName ~= trail._fileName and newFileName ~= "" then
      local oldFilePath = trail._filePath
      local dir, _, ext = path.splitWithoutExt(oldFilePath, true)

      local newFilePath = dir .. newFileName .. "." .. ext

      -- Use the rename function from the main editor
      if editor_crawlEditor and editor_crawlEditor.renameObjectFile then
        editor_crawlEditor.renameObjectFile(oldFilePath, newFilePath, "trail")
      end
    end
  end

  editor.uiInputText("##FileName", self.fileName, nil, nil, nil, nil, nil)

  -- Description
  im.Text("Description")
  editEnded[0] = false
  editor.uiInputText("##TrailDescription", self.description, nil, nil, nil, nil, editEnded)
  if editEnded[0] then
    editor.history:commitAction("Change Trail Description",
      {trail = trail, old = trail.description, new = ffi.string(self.description), field = 'description'},
      setFieldUndo, setFieldRedo)
    markTrailAsDirty(trail)
  end

  -- Mission Properties
  im.Separator()
  im.Text("Mission Properties")

  editEnded[0] = false
  if im.Checkbox("Is Mission Trail", self.isFromMission) then
    editor.history:commitAction("Change Trail Mission Status",
      {trail = trail, old = trail.isFromMission, new = self.isFromMission[0], field = 'isFromMission'},
      setFieldUndo, setFieldRedo)
    markTrailAsDirty(trail)

    if self.isFromMission[0] then
      trail._missionName = trail._fileName
      self.missionName = im.ArrayChar(256, trail._missionName or "")
    end
  end

  if self.isFromMission[0] then
    im.Text("Mission Name: " .. (trail._fileName or "unnamed"))
    im.TextColored(im.ImVec4(0.7, 0.7, 0.7, 1), "(Same as trail name)")
  end

  -- Thumbnail
  im.Separator()
  im.Text("Thumbnail")
  im.SameLine()
  if im.Button("Browse##Thumbnail") then
    extensions.editor_fileDialog.openFile(
      function(data)
        trail.thumbnail = data.filepath
        self.thumbnail = im.ArrayChar(512, trail.thumbnail)
        markTrailAsDirty(trail)
      end,
      nil,
      false,
      "levels/" .. getCurrentLevelIdentifier() .. "/"
    )
  end

  editEnded[0] = false
  editor.uiInputText("##ThumbnailPath", self.thumbnail, nil, nil, nil, nil, editEnded)
  if editEnded[0] then
    editor.history:commitAction("Change Trail Thumbnail",
      {trail = trail, old = trail.thumbnail, new = ffi.string(self.thumbnail), field = 'thumbnail'},
      setFieldUndo, setFieldRedo)
    markTrailAsDirty(trail)
  end

  -- Preview
  im.Text("Preview")
  im.SameLine()
  if im.Button("Browse##Preview") then
    extensions.editor_fileDialog.openFile(
      function(data)
        trail.preview = data.filepath
        self.preview = im.ArrayChar(512, trail.preview)
        markTrailAsDirty(trail)
      end,
      nil,
      false,
      "levels/" .. getCurrentLevelIdentifier() .. "/"
    )
  end

  editEnded[0] = false
  editor.uiInputText("##PreviewPath", self.preview, nil, nil, nil, nil, editEnded)
  if editEnded[0] then
    editor.history:commitAction("Change Trail Preview",
      {trail = trail, old = trail.preview, new = ffi.string(self.preview), field = 'preview'},
      setFieldUndo, setFieldRedo)
    markTrailAsDirty(trail)
  end

  -- Path selection (use the editor's cached lists; saveSystem.getAll* rescans the filesystem)
  im.Text("Path:")
  local allPaths = mergedList(editor_crawlEditor and editor_crawlEditor.getAllPaths and editor_crawlEditor.getAllPaths(), editor_crawlEditor and editor_crawlEditor.getAllMissionPaths)
  local currentPath = nil

  if trail.pathId then
    for i, path in ipairs(allPaths) do
      if path._filePath == trail.pathId then
        currentPath = path
        break
      end
    end
  end

  if im.BeginCombo("##pathCombo", currentPath and currentPath._filePath or "Select Path") then
    for i, path in ipairs(allPaths) do
      local isSelected = currentPath and currentPath._filePath == path._filePath
      if im.Selectable1(path._filePath or "Unnamed Path", isSelected) then
        trail.pathId = path._filePath
        currentPath = path
        markTrailAsDirty(trail)
      end
    end
    im.EndCombo()
  end

  if trail.pathId and trail.pathId ~= "" and not currentPath then
    im.TextColored(missingRefColor, "Missing path: " .. trail.pathId)
  end



  -- Path Reversed option
  if currentPath then
    im.SameLine()
    if im.Checkbox("Reverse Path", self.pathReversed) then
      trail.pathReversed = self.pathReversed[0]
      markTrailAsDirty(trail)
    end
  end

  -- Boundary selection (cached lists; avoid per-frame filesystem rescans)
  im.Text("Boundary:")
  local allBoundaries = mergedList(editor_crawlEditor and editor_crawlEditor.getAllBoundaries and editor_crawlEditor.getAllBoundaries(), editor_crawlEditor and editor_crawlEditor.getAllMissionBoundaries)
  local currentBoundary = nil

  if trail.boundaryId then
    for i, boundary in ipairs(allBoundaries) do
      if boundary._filePath == trail.boundaryId then
        currentBoundary = boundary
        break
      end
    end
  end

  if im.BeginCombo("##boundaryCombo", currentBoundary and currentBoundary._filePath or "Select Boundary") then
    for i, boundary in ipairs(allBoundaries) do
      local isSelected = currentBoundary and currentBoundary._filePath == boundary._filePath
      if im.Selectable1(boundary._filePath or "Unnamed Boundary", isSelected) then
        trail.boundaryId = boundary._filePath
        currentBoundary = boundary
        markTrailAsDirty(trail)
      end
    end
    im.EndCombo()
  end

  if trail.boundaryId and trail.boundaryId ~= "" and not currentBoundary then
    im.TextColored(missingRefColor, "Missing boundary: " .. trail.boundaryId)
  end

  -- Mission detection (check this first)
  local isFromMission = gameplay_crawl_saveSystem.isTrailFromMission(trail)

  -- Show mission info if this is a converted mission
  if trail.isFromMission then
    im.Separator()
    im.TextColored(im.ImVec4(0.8, 0.6, 0.2, 1.0), "Mission Trail")
    im.Text("This trail is from a mission.")
    im.Separator()
  end

  -- Starting Position selection (cached list; avoid per-frame filesystem rescans)
  im.Text("Starting Position:")

  local allStartingPositions = (editor_crawlEditor and editor_crawlEditor.getAllStartingPositions and editor_crawlEditor.getAllStartingPositions()) or {}
  local currentStartingPosition = nil

  if trail.startingPositionId then
    for i, startingPosition in ipairs(allStartingPositions) do
      if startingPosition._filePath == trail.startingPositionId then
        currentStartingPosition = startingPosition
        break
      end
    end
  end

  if im.BeginCombo("##startingPositionCombo", currentStartingPosition and currentStartingPosition._filePath or "Select Starting Position") then
    for i, startingPosition in ipairs(allStartingPositions) do
      local isSelected = currentStartingPosition and currentStartingPosition._filePath == startingPosition._filePath
      if im.Selectable1(startingPosition._filePath or "Unnamed Starting Position", isSelected) then
        trail.startingPositionId = startingPosition._filePath
        currentStartingPosition = startingPosition
        markTrailAsDirty(trail)
      end
    end
    im.EndCombo()
  end

  if trail.startingPositionId and trail.startingPositionId ~= "" and not currentStartingPosition then
    im.TextColored(missingRefColor, "Missing starting position: " .. trail.startingPositionId)
  end

  -- Reversed Starting Position selection (only shown when pathReversed is true)
  if trail.pathReversed then
    im.Separator()
    im.Text("Reversed Starting Position:")

    local allStartingPositions = (editor_crawlEditor and editor_crawlEditor.getAllStartingPositions and editor_crawlEditor.getAllStartingPositions()) or {}
    local currentReversedStartingPosition = nil

    if trail.startingPositionIdReversed then
      for i, startingPosition in ipairs(allStartingPositions) do
        if startingPosition._filePath == trail.startingPositionIdReversed then
          currentReversedStartingPosition = startingPosition
          break
        end
      end
    end

    if im.BeginCombo("##startingPositionReversedCombo", currentReversedStartingPosition and currentReversedStartingPosition._filePath or "Select Reversed Starting Position") then
      for i, startingPosition in ipairs(allStartingPositions) do
        local isSelected = currentReversedStartingPosition and currentReversedStartingPosition._filePath == startingPosition._filePath
        if im.Selectable1(startingPosition._filePath or "Unnamed Starting Position", isSelected) then
          trail.startingPositionIdReversed = startingPosition._filePath
          currentReversedStartingPosition = startingPosition
          markTrailAsDirty(trail)
        end
      end
      im.EndCombo()
    end
  end

  im.Separator()



  -- Prefabs
  im.Separator()
  im.Text("Prefabs:")
  if not trail.prefabs then
    trail.prefabs = {}
  end

    -- Get prefab files for dropdowns
  local prefabFiles = self:getPrefabFiles()

  -- Show dropdown for each existing prefab
  for i, prefabFileName in ipairs(trail.prefabs) do
    im.Text(string.format("Prefab %d:", i))
    im.SameLine()

    -- Find current prefab index in the file list
    local currentIndex = 0
    for j, filePath in ipairs(prefabFiles) do
      local _, filename, _ = path.split(filePath)
      if filename == prefabFileName then
        currentIndex = j - 1
        break
      end
    end

    local selectedIndex = im.IntPtr(currentIndex)

    if im.BeginCombo("##PrefabSelect" .. i, prefabFileName) then
      for j, filePath in ipairs(prefabFiles) do
        local _, filename, _ = path.split(filePath)
        local fileName = filename
        if im.Selectable1(fileName, j-1 == selectedIndex[0]) then
          selectedIndex[0] = j-1
          trail.prefabs[i] = fileName
        end
      end
      im.EndCombo()
    end

    im.SameLine()
    if im.SmallButton("Remove##" .. i) then
      table.remove(trail.prefabs, i)
      markTrailAsDirty(trail)
      break
    end
  end

  -- Add new prefab dropdown
  local addSelectedIndex = im.IntPtr(0)
  if im.BeginCombo("##AddPrefabSelect", "Select new one...") then
    for i, filePath in ipairs(prefabFiles) do
      local _, filename, _ = path.split(filePath)
      local fileName = filename
      if im.Selectable1(fileName, i-1 == addSelectedIndex[0]) then
        addSelectedIndex[0] = i-1
        table.insert(trail.prefabs, fileName)
        markTrailAsDirty(trail)
        addSelectedIndex[0] = 0
      end
    end
    im.EndCombo()
  end

  -- Rules
  im.Separator()
  im.Text("Rules:")
  if not trail.rules then
    trail.rules = {}
  end

  editEnded[0] = false
  editor.uiInputText("##RulesDescription", self.rules, nil, nil, nil, nil, editEnded)
  if editEnded[0] then
    trail.rules.description = ffi.string(self.rules)
    markTrailAsDirty(trail)
  end




end

function C:getNewTrail()
  local defaultThumbnail = ""
  local defaultPreview = ""

  return {
    name = "New Trail",
    description = "A new trail",
    pathId = "",
    boundaryId = "",
    startingPositionId = "",
    startingPositionIdReversed = "",
    pathReversed = false,
    thumbnail = defaultThumbnail,
    preview = defaultPreview,
    prefabs = {},
    rules = {
      description = "Trail rules and requirements"
    },
    metadata = {
      created = os.date(),
      version = "1.0"
    }
  }
end

function C:setTrail(trailParam)
  self.trail = trailParam
end

function C:clearSelection()
  -- No selection to clear
end

function C:setCurrentTab(tab)
  self.currentTab = tab
end

function C:input(mouseInfo)
  -- No input handling needed for trails
end



function C:draw(mouseInfo)
  if not self.trail then return end

  self:input(mouseInfo)

  -- Draw visual indicators for the referenced starting position
  if self.trail.startingPositionId then
    local startingPosition = gameplay_crawl_saveSystem.getStartingPositionById(self.trail.startingPositionId)
    if startingPosition then
      -- Draw area sphere
      debugDrawer:drawSphere(startingPosition.transform.position, startingPosition.transform.radius, ColorF(0, 1, 0, 0.3))
      debugDrawer:drawTextAdvanced(startingPosition.transform.position, String("Trail: " .. self.trail.name), ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 255))

      -- Draw icon position
      debugDrawer:drawSphere(startingPosition.iconPosition, 1.5, ColorF(1, 0, 0, 0.8))
      debugDrawer:drawTextAdvanced(startingPosition.iconPosition, String("Icon"), ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 255))
    end
  end
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end