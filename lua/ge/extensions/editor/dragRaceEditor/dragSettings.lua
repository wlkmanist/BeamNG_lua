-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local constants = require('/lua/ge/extensions/editor/dragRaceEditor/constants')
local state = require('/lua/ge/extensions/editor/dragRaceEditor/state')
local utils = require('/lua/ge/extensions/editor/dragRaceEditor/utils')
local dragSaveSystem = require('/lua/ge/extensions/gameplay/drag/saveSystem')
local im = ui_imgui
local ffi = require('ffi')

local M = {}

local unsavedColor = im.ImVec4(1, 0.3, 0.1, 1.0)

local dragSettings = {
  id = "",
  canBeReseted = true,
  canBeTeleported = true,
  context = "activity",
  dragType = "headsUpRace",
  stripId = "",
  phases = {
    {
      dependency = true,
      name = "stage",
      startedOffset = 0
    },
    {
      dependency = false,
      name = "countdown",
      startedOffset = 0
    },
    {
      dependency = false,
      name = "race",
      startedOffset = 0
    },
    {
      dependency = false,
      name = "stop",
      startedOffset = 0
    }
  },
  prefabs = {
    christmasTree = {
      isUsed = false,
      treeType = ".500"
    },
    displaySign = {
      isUsed = false
    },
    paths = {
      isUsed = false
    },
    decorations = {
      isUsed = false
    }
  },
  timers = nil
}

local allSettingsFiles = {}
local selectedSettingsIndex = -1
local selectedPhaseIndex = -1
local selectedTimerIndex = -1

M.loadAllSettings = function()
  allSettingsFiles = {}

  for _, settingsFile in ipairs(allSettingsFiles) do
    settingsFile._dirty = false
  end

  local levelName = getCurrentLevelIdentifier()
  if not levelName then
    return
  end

  local possibleLevelNames = {}
  table.insert(possibleLevelNames, levelName)
  table.insert(possibleLevelNames, levelName:lower())
  local underscoreName = levelName:gsub(" ", "_")
  table.insert(possibleLevelNames, underscoreName)
  table.insert(possibleLevelNames, underscoreName:lower())

  local foundLevelName = nil
  local foundMissionLevelName = nil
  local addedPaths = {}

  for _, testLevelName in ipairs(possibleLevelNames) do
    local levelDragstripsPath = "/levels/" .. testLevelName .. "/dragstrips/"
    if FS:directoryExists(levelDragstripsPath) then
      foundLevelName = testLevelName
      break
    end
  end

  for _, testLevelName in ipairs(possibleLevelNames) do
    local dragStripRacePath = "/gameplay/missions/" .. testLevelName .. "/dragStripRace/"
    local dragStripAPMPath = "/gameplay/missions/" .. testLevelName .. "/dragStripAPM/"
    if FS:directoryExists(dragStripRacePath) or FS:directoryExists(dragStripAPMPath) then
      foundMissionLevelName = testLevelName
      break
    end
  end

  if foundLevelName then
    local levelDragstripsPath = "/levels/" .. foundLevelName .. "/dragstrips/"
    local levelSettingsFiles = FS:findFiles(levelDragstripsPath, "*.dragSettings.json", -1, true, false)
    for _, file in ipairs(levelSettingsFiles) do
      if not addedPaths[file] then
        addedPaths[file] = true
        local fileName = file:match("([^/]+)$")
        local displayName = fileName
        local json = jsonReadFile(file)
        if json and json.id and json.id ~= "" then
          displayName = json.id
        end
        table.insert(allSettingsFiles, {
          type = "level",
          path = file,
          name = displayName,
          _dirty = false
        })
      end
    end
  end

  if foundMissionLevelName then
    local dragStripRacePath = "/gameplay/missions/" .. foundMissionLevelName .. "/dragStripRace/"
    if FS:directoryExists(dragStripRacePath) then
      local missionDirs = FS:findFiles(dragStripRacePath, "*", 0, false, true)
      for _, missionDir in ipairs(missionDirs) do
        local stat = FS:stat(missionDir)
        if stat.filetype == "dir" then
          local settingsFile = missionDir .. "/dragSettings.json"
          if FS:fileExists(settingsFile) then
            if not addedPaths[settingsFile] then
              addedPaths[settingsFile] = true
              local missionName = missionDir:match("([^/]+)/?$")
              local displayName = missionName or "unknown"
              local json = jsonReadFile(settingsFile)
              if json and json.id and json.id ~= "" then
                displayName = json.id
              end
              table.insert(allSettingsFiles, {
                type = "dragStripRace",
                path = settingsFile,
                name = displayName,
                _dirty = false
              })
            end
          end
        end
      end
    end

    local dragStripAPMPath = "/gameplay/missions/" .. foundMissionLevelName .. "/dragStripAPM/"
    if FS:directoryExists(dragStripAPMPath) then
      local missionDirs = FS:findFiles(dragStripAPMPath, "*", 0, false, true)
      for _, missionDir in ipairs(missionDirs) do
        local stat = FS:stat(missionDir)
        if stat.filetype == "dir" then
          local settingsFile = missionDir .. "/dragSettings.json"
          if FS:fileExists(settingsFile) then
            if not addedPaths[settingsFile] then
              addedPaths[settingsFile] = true
              local missionName = missionDir:match("([^/]+)/?$")
              local displayName = missionName or "unknown"
              local json = jsonReadFile(settingsFile)
              if json and json.id and json.id ~= "" then
                displayName = json.id
              end
              table.insert(allSettingsFiles, {
                type = "dragStripAPM",
                path = settingsFile,
                name = displayName,
                _dirty = false
              })
            end
          end
        end
      end
    end
  end
end

M.getAllSettings = function()
  return allSettingsFiles
end

M.getSelectedSettingsIndex = function()
  return selectedSettingsIndex
end

M.setSelectedSettingsIndex = function(index)
  selectedSettingsIndex = index
end

M.getSelectedSettings = function()
  if selectedSettingsIndex > 0 and selectedSettingsIndex <= #allSettingsFiles then
    return allSettingsFiles[selectedSettingsIndex]
  end
  return nil
end

M.selectSettings = function(index)
  local previousSettingsFile = M.getSelectedSettings()
  if previousSettingsFile and previousSettingsFile._dirty then
    previousSettingsFile._cachedData = deepcopy(dragSettings)
  end

  selectedSettingsIndex = index

  local strips = require('/lua/ge/extensions/editor/dragRaceEditor/strips')
  strips.setSelectedStripIndex(-1)
  selectedPhaseIndex = -1
  selectedTimerIndex = -1

  local settingsFile = M.getSelectedSettings()
  if settingsFile then
    log('D', 'drag_race_editor', 'Selected settings file: ' .. settingsFile.name)
    if settingsFile._dirty and settingsFile._cachedData then
      dragSettings = deepcopy(settingsFile._cachedData)
    elseif FS:fileExists(settingsFile.path) and not settingsFile._dirty then
      M.loadDragSettings(settingsFile.path)
    elseif not FS:fileExists(settingsFile.path) then
      if not dragSettings.id or dragSettings.id == "" then
        dragSettings.id = settingsFile.name
      end
    end
  end
end

M.drawSettingsList = function()
  im.Spacing()
  if not utils.dragSectionHeader("Drag Settings", "##settingsList", true) then
    return
  end

  local strips = require('/lua/ge/extensions/editor/dragRaceEditor/strips')
  local hasSavedStrips = strips.hasSavedStrips()

  if not hasSavedStrips then
    im.BeginDisabled()
  end

  if im.Button("Add##settings_add") then
    log('D', 'drag_race_editor', 'Settings Add button clicked')

    editor_fileDialog.saveFile(function(data)
      if not data or not data.filepath then
        return
      end

      local sanitizedPath = data.filepath:gsub("[*?<>|\"]", "")

      if not sanitizedPath:match("%.dragSettings%.json$") then
        sanitizedPath = sanitizedPath:gsub("%.json$", "") .. ".dragSettings.json"
      end

      local fileName = sanitizedPath:match("([^/]+)$") or "settings"
      local fileType = "level"
      if sanitizedPath:match("/gameplay/missions/") then
        fileType = "mission"
      elseif sanitizedPath:match("/dragStripRace/") then
        fileType = "dragStripRace"
      elseif sanitizedPath:match("/dragStripAPM/") then
        fileType = "dragStripAPM"
      end

      local defaultId = fileName:gsub("%.dragSettings%.json$", "")
      defaultId = defaultId:gsub("[*?<>|\":/\\]", "")
      if defaultId == "" then
        defaultId = "new_settings_" .. (#allSettingsFiles + 1)
      end

      local newSettingsFile = {
        type = fileType,
        path = sanitizedPath,
        name = defaultId,
        _dirty = true,
        _fileExists = false
      }

      table.insert(allSettingsFiles, newSettingsFile)
      M.selectSettings(#allSettingsFiles)

      dragSettings = {
        id = defaultId,
        stripId = "",
        dragType = "headsUpRace",
        context = "activity",
        phases = {
          {
            dependency = true,
            name = "stage",
            startedOffset = 0
          },
          {
            dependency = false,
            name = "countdown",
            startedOffset = 0
          },
          {
            dependency = false,
            name = "race",
            startedOffset = 0
          },
          {
            dependency = false,
            name = "stop",
            startedOffset = 0
          }
        },
        prefabs = {
          christmasTree = {
            isUsed = true,
            treeType = ".500",
            prefabPath = ""
          },
          displaySign = {
            isUsed = true,
            prefabPath = ""
          },
          paths = {
            isUsed = false,
            prefabPath = ""
          },
          decorations = {
            isUsed = false,
            prefabPath = ""
          }
        },
        timers = deepcopy(dragSaveSystem.DEFAULT_TIMERS),
        canBeReseted = true,
        canBeTeleported = true
      }

      log('D', 'drag_race_editor', 'Created drag settings (unsaved): ' .. defaultId .. ' at ' .. sanitizedPath)
    end, {{"Drag Settings Files", "*.dragSettings.json"}}, false, "levels")
  end

  if not hasSavedStrips then
    im.EndDisabled()
    if im.IsItemHovered() then
      im.tooltip("Create and save at least one strip before creating drag settings")
    end
  end
  im.SameLine()
  if im.Button("Remove##settings_remove") then
    log('D', 'drag_race_editor', 'Settings Remove button clicked')
    im.tooltip("Remove functionality not yet implemented")
  end
  im.SameLine()
  if im.Button("Save##settings_save") then
    log('D', 'drag_race_editor', 'Settings Save button clicked')
    local settingsFile = M.getSelectedSettings()
    if settingsFile then
      M.saveDragSettings(settingsFile.path)
    end
  end
  im.SameLine()
  if im.Button("Refresh##settings_refresh") then
    log('D', 'drag_race_editor', 'Settings Refresh button clicked')
    M.loadAllSettings()
  end

  im.NewLine()

  for i, settingsFile in ipairs(allSettingsFiles) do
    local isSelected = i == selectedSettingsIndex
    local label = string.format("[%s] %s", settingsFile.type, settingsFile.name)

    if settingsFile._dirty then
      im.PushStyleColor2(im.Col_Text, unsavedColor)
    end

    local wasSelected = im.Selectable1(label, isSelected)

    if settingsFile._dirty then
      im.PopStyleColor()
    end

    if wasSelected then
      M.selectSettings(i)
    end

    if im.IsItemHovered() then
      local tooltip = string.format("ID: %s\nType: %s\nPath: %s", settingsFile.name, settingsFile.type, settingsFile.path)
      if settingsFile._dirty then
        tooltip = tooltip .. "\n[UNSAVED CHANGES]"
      end
      im.tooltip(tooltip)
    end
  end

  im.Spacing()
end

M.drawSettingsDetails = function()
  local settingsFile = M.getSelectedSettings()
  if not settingsFile then
    return
  end

  local sidx = tostring(M.getSelectedSettingsIndex())
  local settingsTitle = dragSettings.id or settingsFile.name or "Settings"
  im.Spacing()
  if not utils.dragSectionHeader(settingsTitle, "##settingsRoot" .. sidx, true) then
    return
  end

  im.Spacing()
  if utils.dragSectionHeader("Basics", "##settingsBasics" .. sidx, true) then

  im.Text("ID: ")
  im.SameLine()
  local id = im.ArrayChar(256, dragSettings.id or "")
  if im.InputText("##settingsId", id, 256) then
    dragSettings.id = ffi.string(id)
    M.markDirty()
    utils.markUnsavedChanges()
  end

  im.Text("File: " .. settingsFile.name)
  im.Text("Type: " .. settingsFile.type)
  im.Text("Path: " .. settingsFile.path)

  im.Separator()

  im.Text("Can Be Reset: ")
  im.SameLine()
  local canBeReseted = im.BoolPtr(dragSettings.canBeReseted or false)
  if im.Checkbox("##canBeReseted", canBeReseted) then
    dragSettings.canBeReseted = canBeReseted[0]
    M.markDirty()
    utils.markUnsavedChanges()
  end

  im.Text("Can Be Teleported: ")
  im.SameLine()
  local canBeTeleported = im.BoolPtr(dragSettings.canBeTeleported or false)
  if im.Checkbox("##canBeTeleported", canBeTeleported) then
    dragSettings.canBeTeleported = canBeTeleported[0]
    M.markDirty()
    utils.markUnsavedChanges()
  end

  im.Text("Context: ")
  im.SameLine()
  local context = im.ArrayChar(256, dragSettings.context or "")
  if im.InputText("##context", context, 256) then
    dragSettings.context = ffi.string(context)
    M.markDirty()
    utils.markUnsavedChanges()
  end

  im.Text("Drag Type: ")
  im.SameLine()
  im.PushItemWidth(100)
  local dragTypes = {"headsUpRace", "bracketRace"}
  local search = state.getSearch()
  local selectedDragType = search:beginSearchableSimpleCombo(im, "dragType", dragSettings.dragType or "headsUpRace", dragTypes)
  if selectedDragType then
    dragSettings.dragType = selectedDragType
    M.markDirty()
    utils.markUnsavedChanges()
  end
  im.PopItemWidth()

  im.Text("Strip ID: ")
  im.SameLine()
  local allStrips = dragSaveSystem.getAllStrips()
  local stripOptions = {}
  local currentStripIndex = 0
  local levelPath = dragSaveSystem.getCurrentLevelDragPath()

  for i, strip in ipairs(allStrips) do
    local stripPath = levelPath and (levelPath .. strip.id .. ".strip.json") or ""
    table.insert(stripOptions, strip.id)
    if dragSettings.stripId then
      if dragSettings.stripId == stripPath or dragSettings.stripId == strip.id or
         dragSettings.stripId:match(strip.id .. "%.strip%.json$") then
        currentStripIndex = i
      end
    end
  end

  if #stripOptions > 0 then
    im.PushItemWidth(200)
    local search = state.getSearch()
    local selectedStripId = search:beginSearchableSimpleCombo(im, "stripId", stripOptions[currentStripIndex] or stripOptions[1], stripOptions)
    if selectedStripId then
      if levelPath then
        dragSettings.stripId = levelPath .. selectedStripId .. ".strip.json"
      else
        dragSettings.stripId = selectedStripId
      end
      M.markDirty()
      utils.markUnsavedChanges()
    end
    im.PopItemWidth()
  else
    im.Text("No strips available")
  end

  end

  im.Spacing()
  if utils.dragSectionHeader("Phases", "##settingsPhases" .. sidx, true) then

  if im.Button("Add Phase") then
    table.insert(dragSettings.phases, {
      dependency = false,
      name = "newPhase",
      startedOffset = 0
    })
    M.markDirty()
    utils.markUnsavedChanges()
  end

  im.SameLine()
  if im.Button("Remove Selected Phase") then
    if selectedPhaseIndex > 0 and selectedPhaseIndex <= #dragSettings.phases then
      table.remove(dragSettings.phases, selectedPhaseIndex)
      selectedPhaseIndex = -1
      M.markDirty()
      utils.markUnsavedChanges()
    end
  end

  im.NewLine()

  for i, phase in ipairs(dragSettings.phases) do
    local isSelected = i == selectedPhaseIndex
    local phaseLabel = string.format("%d. %s", i, phase.name)

    if im.Selectable1(phaseLabel, isSelected) then
      selectedPhaseIndex = i
    end
  end

  if selectedPhaseIndex > 0 and selectedPhaseIndex <= #dragSettings.phases then
    local phase = dragSettings.phases[selectedPhaseIndex]

    im.Spacing()
    if utils.dragSectionHeader(phase.name or "Phase", "##settingsPhaseDetail" .. sidx .. "_" .. tostring(selectedPhaseIndex), true) then

    im.Text("Name:")
    im.SameLine()
    local phaseName = im.ArrayChar(256, phase.name or "")
    if im.InputText("##phaseName", phaseName, 256) then
      phase.name = ffi.string(phaseName)
      M.markDirty()
      utils.markUnsavedChanges()
    end

    local dependency = im.BoolPtr(phase.dependency or false)
    if im.Checkbox("Dependency", dependency) then
      phase.dependency = dependency[0]
      M.markDirty()
      utils.markUnsavedChanges()
    end

    im.Text("Started Offset:")
    im.SameLine()
    local offset = im.IntPtr(phase.startedOffset or 0)
    if im.InputInt("##phaseOffset", offset) then
      phase.startedOffset = offset[0]
      M.markDirty()
      utils.markUnsavedChanges()
    end
    end
  end

  end

  im.Spacing()
  if utils.dragSectionHeader("Timers", "##settingsTimers" .. sidx, true) then
  im.TextWrapped("Recorded times/velocities; one \"important\" timer determines the winner.")
  im.Spacing()
  if not dragSettings.timers then
    dragSettings.timers = deepcopy(dragSaveSystem.DEFAULT_TIMERS)
    M.markDirty()
  end
  if im.Button("Add Timer") then
    table.insert(dragSettings.timers, {
      id = "timer_" .. (#dragSettings.timers + 1),
      label = "New Timer",
      type = "distanceTimer",
      distance = 402.336,
      important = false
    })
    M.markDirty()
    utils.markUnsavedChanges()
  end
  im.SameLine()
  if im.Button("Remove Selected Timer") then
    if selectedTimerIndex > 0 and selectedTimerIndex <= #dragSettings.timers then
      table.remove(dragSettings.timers, selectedTimerIndex)
      selectedTimerIndex = -1
      M.markDirty()
      utils.markUnsavedChanges()
    end
  end
  im.NewLine()
  for i, t in ipairs(dragSettings.timers) do
    local isSelected = i == selectedTimerIndex
    local row = string.format("%d. %s (%s) @ %.1fm%s", i, t.label or "?", t.type or "?", t.distance or 0, (t.important and " [WIN]") or "")
    if im.Selectable1(row, isSelected) then
      selectedTimerIndex = i
    end
  end
  if selectedTimerIndex > 0 and selectedTimerIndex <= #dragSettings.timers then
    local t = dragSettings.timers[selectedTimerIndex]
    im.Spacing()
    if utils.dragSectionHeader(t.label or "Timer", "##settingsTimerDetail" .. sidx .. "_" .. tostring(selectedTimerIndex), true) then
    im.Text("Label:")
    im.SameLine()
    local labelBuf = im.ArrayChar(128, t.label or "")
    if im.InputText("##timerLabel", labelBuf, 128) then
      t.label = ffi.string(labelBuf)
      M.markDirty()
      utils.markUnsavedChanges()
    end
    im.Text("Type:")
    im.SameLine()
    im.PushItemWidth(120)
    local types = {"distanceTimer", "velocity"}
    local search = state.getSearch()
    local selType = search:beginSearchableSimpleCombo(im, "timerType", t.type or "distanceTimer", types)
    if selType then
      t.type = selType
      M.markDirty()
      utils.markUnsavedChanges()
    end
    im.PopItemWidth()
    im.Text("Distance (m):")
    im.SameLine()
    local distPtr = im.FloatPtr(t.distance or 0)
    if im.InputFloat("##timerDistance", distPtr, 1, 10, "%.2f") then
      t.distance = math.max(0, distPtr[0])
      M.markDirty()
      utils.markUnsavedChanges()
    end
    im.Text("Important (determines winner):")
    im.SameLine()
    local importantPtr = im.BoolPtr(t.important or false)
    if im.Checkbox("##timerImportant", importantPtr) then
      if importantPtr[0] then
        for _, o in ipairs(dragSettings.timers) do o.important = false end
        t.important = true
      else
        t.important = false
      end
      M.markDirty()
      utils.markUnsavedChanges()
    end
    if im.IsItemHovered() then
      im.tooltip("Only one timer can be important. It is used to determine who wins.")
    end
    if im.Button("Move Up##timer") and selectedTimerIndex > 1 then
      utils.reorderLanes(dragSettings.timers, selectedTimerIndex, selectedTimerIndex - 1)
      selectedTimerIndex = selectedTimerIndex - 1
      M.markDirty()
      utils.markUnsavedChanges()
    end
    im.SameLine()
    if im.Button("Move Down##timer") and selectedTimerIndex < #dragSettings.timers then
      utils.reorderLanes(dragSettings.timers, selectedTimerIndex, selectedTimerIndex + 1)
      selectedTimerIndex = selectedTimerIndex + 1
      M.markDirty()
      utils.markUnsavedChanges()
    end
    end
  end

  end

  im.Spacing()
  if utils.dragSectionHeader("Prefabs", "##settingsPrefabs" .. sidx, true) then

  im.Text("Christmas Tree:")
  im.SameLine()
  local christmasTreeUsed = im.BoolPtr(dragSettings.prefabs.christmasTree.isUsed or false)
  if im.Checkbox("Enabled##christmasTree", christmasTreeUsed) then
    dragSettings.prefabs.christmasTree.isUsed = christmasTreeUsed[0]
    M.markDirty()
    utils.markUnsavedChanges()
  end

  if dragSettings.prefabs.christmasTree.isUsed then
    im.SameLine()
    im.Text("Type:")
    im.SameLine()
    im.PushItemWidth(100)
    local treeTypes = {".400", ".500"}
    local search = state.getSearch()
    local selectedTreeType = search:beginSearchableSimpleCombo(im, "treeType", dragSettings.prefabs.christmasTree.treeType or ".500", treeTypes)
    if selectedTreeType then
      dragSettings.prefabs.christmasTree.treeType = selectedTreeType
      M.markDirty()
      utils.markUnsavedChanges()
    end
    im.PopItemWidth()

    im.NewLine()
    im.Text("Prefab Path:")
    im.SameLine()
    local christmasTreePath = im.ArrayChar(512, dragSettings.prefabs.christmasTree.prefabPath or "")
    if im.InputText("##christmasTreePath", christmasTreePath, 512) then
      dragSettings.prefabs.christmasTree.prefabPath = ffi.string(christmasTreePath)
      M.markDirty()
      utils.markUnsavedChanges()
    end
    im.SameLine()
    if im.Button("Browse##christmasTree") then
      editor_fileDialog.openFile("Select Christmas Tree Prefab", "*.prefab", function(path)
        if path then
          dragSettings.prefabs.christmasTree.prefabPath = path
          M.markDirty()
          utils.markUnsavedChanges()
        end
      end)
    end
  end

  im.NewLine()

  im.Text("Display Sign:")
  im.SameLine()
  local displaySignUsed = im.BoolPtr(dragSettings.prefabs.displaySign.isUsed or false)
  if im.Checkbox("Enabled##displaySign", displaySignUsed) then
    dragSettings.prefabs.displaySign.isUsed = displaySignUsed[0]
    M.markDirty()
    utils.markUnsavedChanges()
  end

  if dragSettings.prefabs.displaySign.isUsed then
    im.NewLine()
    im.Text("Prefab Path:")
    im.SameLine()
    local displaySignPath = im.ArrayChar(512, dragSettings.prefabs.displaySign.prefabPath or "")
    if im.InputText("##displaySignPath", displaySignPath, 512) then
      dragSettings.prefabs.displaySign.prefabPath = ffi.string(displaySignPath)
      M.markDirty()
      utils.markUnsavedChanges()
    end
    im.SameLine()
    if im.Button("Browse##displaySign") then
      editor_fileDialog.openFile("Select Display Sign Prefab", "*.prefab", function(path)
        if path then
          dragSettings.prefabs.displaySign.prefabPath = path
          M.markDirty()
          utils.markUnsavedChanges()
        end
      end)
    end
  end

  im.NewLine()

  im.Text("Paths:")
  im.SameLine()
  local pathsUsed = im.BoolPtr(dragSettings.prefabs.paths.isUsed or false)
  if im.Checkbox("Enabled##paths", pathsUsed) then
    dragSettings.prefabs.paths.isUsed = pathsUsed[0]
    M.markDirty()
    utils.markUnsavedChanges()
  end

  if dragSettings.prefabs.paths.isUsed then
    im.NewLine()
    im.Text("Prefab Path:")
    im.SameLine()
    local pathsPath = im.ArrayChar(512, dragSettings.prefabs.paths.prefabPath or "")
    if im.InputText("##pathsPath", pathsPath, 512) then
      dragSettings.prefabs.paths.prefabPath = ffi.string(pathsPath)
      M.markDirty()
      utils.markUnsavedChanges()
    end
    im.SameLine()
    if im.Button("Browse##paths") then
      editor_fileDialog.openFile("Select Paths Prefab", "*.prefab", function(path)
        if path then
          dragSettings.prefabs.paths.prefabPath = path
          M.markDirty()
          utils.markUnsavedChanges()
        end
      end)
    end
  end

  im.NewLine()

  im.Text("Decorations:")
  im.SameLine()
  local decorationsUsed = im.BoolPtr(dragSettings.prefabs.decorations.isUsed or false)
  if im.Checkbox("Enabled##decorations", decorationsUsed) then
    dragSettings.prefabs.decorations.isUsed = decorationsUsed[0]
    M.markDirty()
    utils.markUnsavedChanges()
  end

  if dragSettings.prefabs.decorations.isUsed then
    im.NewLine()
    im.Text("Prefab Path:")
    im.SameLine()
    local decorationsPath = im.ArrayChar(512, dragSettings.prefabs.decorations.prefabPath or "")
    if im.InputText("##decorationsPath", decorationsPath, 512) then
      dragSettings.prefabs.decorations.prefabPath = ffi.string(decorationsPath)
      M.markDirty()
      utils.markUnsavedChanges()
    end
    im.SameLine()
    if im.Button("Browse##decorations") then
      editor_fileDialog.openFile("Select Decorations Prefab", "*.prefab", function(path)
        if path then
          dragSettings.prefabs.decorations.prefabPath = path
          M.markDirty()
          utils.markUnsavedChanges()
        end
      end)
    end
  end

  end

  im.Spacing()
end

M.getDragSettings = function()
  return dragSettings
end

M.setDragSettings = function(settings)
  dragSettings = settings or dragSettings
end

M.markDirty = function()
  local settingsFile = M.getSelectedSettings()
  if settingsFile then
    settingsFile._dirty = true
    settingsFile._cachedData = deepcopy(dragSettings)
  end
end

M.loadDragSettings = function(filePath)
  local json = jsonReadFile(filePath)
  if json then
    dragSettings = json
    dragSettings.facilityId = nil
    if not dragSettings.id or dragSettings.id == "" then
      local _, filename, _ = path.splitWithoutExt(filePath, true)
      dragSettings.id = filename or ""
    end
    if not dragSettings.timers or type(dragSettings.timers) ~= "table" or #dragSettings.timers == 0 then
      dragSettings.timers = deepcopy(dragSaveSystem.DEFAULT_TIMERS)
    end
    for _, settingsFile in ipairs(allSettingsFiles) do
      if settingsFile.path == filePath then
        settingsFile._dirty = false
        break
      end
    end
    log('D', 'drag_race_editor', 'Loaded drag settings from: ' .. filePath)
    return true
  else
    utils.logError("Failed to load drag settings from: " .. filePath)
    return false
  end
end

M.saveDragSettings = function(filePath)
  local valid, error = M.validateDragSettings(dragSettings)
  if not valid then
    utils.logError("Cannot save drag settings: " .. error)
    return false
  end

  local settingsFile = M.getSelectedSettings()
  if not settingsFile then
    utils.logError("No settings file selected")
    return false
  end

  local newFilePath = filePath or settingsFile.path
  if not newFilePath then
    utils.logError("No file path specified for drag settings")
    return false
  end

  newFilePath = newFilePath:gsub("[*?<>|\"]", "")

  if not newFilePath:match("%.dragSettings%.json$") then
    newFilePath = newFilePath:gsub("%.json$", "") .. ".dragSettings.json"
  end

  local levelPath = dragSaveSystem.getCurrentLevelDragPath()
  if dragSettings.id and dragSettings.id ~= "" and levelPath and
     settingsFile.path and settingsFile.path:match("^" .. levelPath:gsub("%/", "%%/")) then
    local potentialNewPath = levelPath .. dragSettings.id .. ".dragSettings.json"
    if potentialNewPath ~= newFilePath and FS:fileExists(settingsFile.path) then
      if FS:fileExists(potentialNewPath) then
        utils.logError("Cannot rename drag settings: file with new ID already exists: " .. potentialNewPath)
        return false
      end

      local renameResult = FS:renameFile(settingsFile.path, potentialNewPath)
      if renameResult ~= 0 then
        utils.logError("Failed to rename drag settings file from " .. settingsFile.path .. " to " .. potentialNewPath)
        return false
      end

      newFilePath = potentialNewPath
      log('D', 'drag_race_editor', 'Renamed drag settings file from ' .. settingsFile.path .. ' to ' .. newFilePath)
    end
  end

  local dirPath = newFilePath:match("^(.-)/[^/]+$")
  if dirPath and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
    if not FS:directoryExists(dirPath) then
      utils.logError("Failed to create directory: " .. dirPath)
      return false
    end
  end

  local cleanData = deepcopy(dragSettings)
  cleanData.facilityId = nil
  local success = jsonWriteFile(newFilePath, cleanData, true)

  if success then
    log('D', 'drag_race_editor', 'Saved drag settings to: ' .. newFilePath)
    settingsFile.path = newFilePath
    settingsFile.name = dragSettings.id or (settingsFile.name or "settings")
    settingsFile._dirty = false
    settingsFile._fileExists = true
  end

  return success
end

M.validateDragSettings = function(settings)
  if not settings then return false, "No settings provided" end
  if not settings.dragType or settings.dragType == "" then
    return false, "Drag type not selected"
  end
  if not settings.stripId or settings.stripId == "" then
    return false, "Strip ID not specified"
  end
  return true
end

M.drawDragSettingsSection = function()
  im.BeginChild1("dragSettings", im.ImVec2(0, 200), true)
  im.Text("Drag Settings")
  im.Separator()

  im.Text("Can Be Reset: ")
  im.SameLine()
  local canBeReseted = im.BoolPtr(dragSettings.canBeReseted or false)
  if im.Checkbox("##canBeReseted", canBeReseted) then
    dragSettings.canBeReseted = canBeReseted[0]
    M.markDirty()
    utils.markUnsavedChanges()
  end

  im.Text("Can Be Teleported: ")
  im.SameLine()
  local canBeTeleported = im.BoolPtr(dragSettings.canBeTeleported or false)
  if im.Checkbox("##canBeTeleported", canBeTeleported) then
    dragSettings.canBeTeleported = canBeTeleported[0]
    M.markDirty()
    utils.markUnsavedChanges()
  end

  im.Text("Context: ")
  im.SameLine()
  local context = im.ArrayChar(256, dragSettings.context or "")
  if im.InputText("##context", context, 256) then
    dragSettings.context = ffi.string(context)
    M.markDirty()
    utils.markUnsavedChanges()
  end

  im.Text("Drag Type: ")
  im.SameLine()
  im.PushItemWidth(100)
  local dragTypes = {"headsUpRace", "bracketRace"}
  local search = state.getSearch()
  local selectedDragType = search:beginSearchableSimpleCombo(im, "dragType", dragSettings.dragType or "headsUpRace", dragTypes)
  if selectedDragType then
    dragSettings.dragType = selectedDragType
    M.markDirty()
    utils.markUnsavedChanges()
  end
  im.PopItemWidth()

  im.Text("Strip ID: ")
  im.SameLine()
  local levelPath = dragSaveSystem.getCurrentLevelDragPath()
  local allStrips = dragSaveSystem.getAllStrips()
  local stripOptions = {}
  local currentStripIndex = 0

  for i, strip in ipairs(allStrips) do
    local stripPath = levelPath and (levelPath .. strip.id .. ".strip.json") or ""
    table.insert(stripOptions, strip.id)
    if dragSettings.stripId then
      if dragSettings.stripId == stripPath or dragSettings.stripId == strip.id or
         dragSettings.stripId:match(strip.id .. "%.strip%.json$") then
        currentStripIndex = i
      end
    end
  end

  if #stripOptions > 0 then
    im.PushItemWidth(200)
    local search = state.getSearch()
    local selectedStripId = search:beginSearchableSimpleCombo(im, "stripIdSection", stripOptions[currentStripIndex] or stripOptions[1], stripOptions)
    if selectedStripId then
      if levelPath then
        dragSettings.stripId = levelPath .. selectedStripId .. ".strip.json"
      else
        dragSettings.stripId = selectedStripId
      end
      M.markDirty()
      utils.markUnsavedChanges()
    end
    im.PopItemWidth()
  else
    im.Text("No strips available")
  end

  im.EndChild()
end

M.drawPrefabsSection = function()
  im.BeginChild1("prefabs", im.ImVec2(0, 200), true)
  im.Text("Prefabs")
  im.Separator()

  local function drawPrefabHelper(label, prefabType)
    im.Text(label)
    im.SameLine()
    local boolptr = im.BoolPtr(dragSettings.prefabs[prefabType].isUsed or false)
    if im.Checkbox("##isUsed_" .. label, boolptr) then
      dragSettings.prefabs[prefabType].isUsed = boolptr[0]
      M.markDirty()
      utils.markUnsavedChanges()
    end

    if im.IsItemHovered() then
      im.tooltip("Enable to use prefab for this component")
    end

    im.SameLine()
    if im.Button("Load...##" .. label) then
      editor_fileDialog.openFile(function(data)
        dragSettings.prefabs[prefabType].path = data.filepath
        M.markDirty()
        utils.markUnsavedChanges()
      end, {{"Prefab Files", ".prefab.json"}}, false)
    end

    if dragSettings.prefabs[prefabType].path then
      im.SameLine()
      im.TextColored(constants.CONSTANTS.COLORS.SUCCESS, "Loaded!")
      im.SameLine()
      if im.Button("Clear##" .. label) then
        dragSettings.prefabs[prefabType].path = nil
        M.markDirty()
        utils.markUnsavedChanges()
      end
    elseif dragSettings.prefabs[prefabType].isUsed then
      im.SameLine()
      im.TextColored(constants.CONSTANTS.COLORS.WARNING, "No prefab loaded")
    end
  end

  drawPrefabHelper("Christmas Tree: ", "christmasTree")

  if dragSettings.prefabs.christmasTree.isUsed then
    im.PushItemWidth(80)
    im.Text("Tree Type: ")
    im.SameLine()
    local search = state.getSearch()
    local tType = search:beginSearchableSimpleCombo(im, "treeType",
      dragSettings.prefabs.christmasTree.treeType, constants.CONSTANTS.TREE_TYPES)
    if tType then
      dragSettings.prefabs.christmasTree.treeType = tType
      M.markDirty()
      utils.markUnsavedChanges()
    end
    im.PopItemWidth()
  end

  drawPrefabHelper("Display Sign: ", "displaySign")
  drawPrefabHelper("AI Path: ", "paths")
  drawPrefabHelper("Decoration: ", "decorations")

  im.EndChild()
end

M.drawPhasesSection = function()
  im.BeginChild1("phases", im.ImVec2(0, 150), true)
  im.Text("Race Phases")
  im.Separator()

  im.PushItemWidth(constants.CONSTANTS.UI.INPUT_WIDTH)
  local search = state.getSearch()
  local phase = search:beginSearchableSimpleCombo(im, "phase", "Select Phase", constants.CONSTANTS.RACE_PHASES)
  if phase then
    table.insert(dragSettings.phases, {
      name = phase,
      dependency = true,
      startedOffset = 0,
    })
    M.markDirty()
    utils.markUnsavedChanges()
  end
  im.PopItemWidth()

  for i, p in ipairs(dragSettings.phases) do
    im.Text(i .. ". " .. p.name)
    im.SameLine()
    if im.Button("Remove##phase" .. i) then
      table.remove(dragSettings.phases, i)
      M.markDirty()
      utils.markUnsavedChanges()
    end

    if i > 1 then
      im.SameLine()
      if im.Button("↑##up" .. i) then
        utils.reorderLanes(dragSettings.phases, i, i - 1)
        M.markDirty()
        utils.markUnsavedChanges()
      end
    end

    if i < #dragSettings.phases then
      im.SameLine()
      if im.Button("↓##down" .. i) then
        utils.reorderLanes(dragSettings.phases, i, i + 1)
        M.markDirty()
        utils.markUnsavedChanges()
      end
    end

    im.SameLine()
    local dependency = im.BoolPtr(p.dependency)
    if im.Checkbox("Dependencies##" .. i, dependency) then
      p.dependency = dependency[0]
      M.markDirty()
      utils.markUnsavedChanges()
    end
  end

  im.EndChild()
end

return M
