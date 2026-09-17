-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
local im = ui_imgui
local ffi = require('ffi')

local logTag = "crawl_editor_presets"
local saveSystem = require('/lua/ge/extensions/gameplay/crawl/saveSystem')

local function getCurrentLevelCrawlPath()
  local levelName = getCurrentLevelIdentifier()
  if not levelName then
    return nil
  end
  return '/levels/' .. levelName .. '/crawls/'
end

local function getPresetsFile()
  local levelName = getCurrentLevelIdentifier()
  if not levelName then
    return "settings/cloud/crawls/presets.json"
  end
  return '/levels/' .. levelName .. '/crawls/presets.json'
end

local PRESET_EXTENSION = ".preset.json"

local PRESET_CATEGORIES = {
  TRAILS = "trails",
  BOUNDARIES = "boundaries",
  PATHNODES = "pathnodes"
}

function C:init()
  self.presets = {
    categories = {
      [PRESET_CATEGORIES.TRAILS] = {},
      [PRESET_CATEGORIES.BOUNDARIES] = {},
      [PRESET_CATEGORIES.PATHNODES] = {}
    },
    metadata = {
      created = os.date(),
      modified = os.date(),
      description = "Crawl Editor Presets"
    }
  }

  self.showSaveBoundaryDialog = false
  self.showSavePathnodeDialog = false
  self.showSaveTrailDialog = false
  self.showPresetManager = false
  self.showPresetManagerPtr = im.BoolPtr(false)
  self.boundaryPresetName = im.ArrayChar(256, "")
  self.pathnodePresetName = im.ArrayChar(256, "")
  self.trailPresetName = im.ArrayChar(256, "")

  self.PRESETS_FILE = getPresetsFile()
  self.PRESET_EXTENSION = PRESET_EXTENSION
  self.PRESET_CATEGORIES = PRESET_CATEGORIES

  self:loadPresets()
end

local function validatePresetData(data, category)
  if not data then return false, "No preset data" end
  if not data.name then return false, "Missing preset name" end
  if not data.category then return false, "Missing preset category" end
  if data.category ~= category then return false, "Category mismatch" end
  if not data.data then return false, "Missing preset data" end
  return true
end

local function validateBoundaryPreset(data)
  if not data.name then return false, "Missing boundary name" end
  if not data.vertices or #data.vertices == 0 then return false, "No boundary vertices" end
  return true
end

local function validatePathnodePreset(data)
  if not data.name then return false, "Missing path name" end
  if not data.nodes or #data.nodes == 0 then
    return false, "No nodes in path"
  end
  return true
end

local function validateTrailPreset(data)
  if not data.name then return false, "Missing trail name" end
  if not data.path then return false, "Missing trail path" end
  if not data.boundary then return false, "Missing trail boundary" end
  return true
end

local function serializeBoundaryPreset(boundary)
  if not boundary or not boundary.onSerialize then
    log('E', logTag, 'Invalid boundary object for preset serialization')
    return nil
  end

  local serializedData = boundary:onSerialize()
  local isValid, errorMsg = validateBoundaryPreset(serializedData)
  if not isValid then
    log('E', logTag, 'Invalid boundary data: ' .. errorMsg)
    return nil
  end

  return serializedData
end

local function serializePathnodePreset(path)
  if not path then
    log('E', logTag, 'Invalid path object for preset serialization')
    return nil
  end

  local serializedData = {
    name = path.name or "",
    description = path.description or "",
    nodes = {}
  }
  if path.nodes then
    for i, n in ipairs(path.nodes) do
      table.insert(serializedData.nodes, {
        name = n.name or ("Node " .. i),
        position = n.pos and n.pos:toTable() or {0,0,0},
        rotation = n.rot and n.rot:toTable() or {0,0,0,1},
        radius = n.radius or 6.0,
        flags = n.flags or {}
      })
    end
  end
  local isValid, errorMsg = validatePathnodePreset(serializedData)
  if not isValid then
    log('E', logTag, 'Invalid path data: ' .. errorMsg)
    return nil
  end

  return serializedData
end

local function serializeTrailPreset(trail)
  if not trail then
    log('E', logTag, 'No trail object for preset serialization')
    return nil
  end

      local serializedTrail = trail:onSerialize()

  if trail.path and trail.path.onSerialize then
    serializedTrail.path = trail.path:onSerialize()
  else
    log('E', logTag, 'Trail has no path or invalid path object')
    return nil
  end

  if trail.boundary and trail.boundary.onSerialize then
    serializedTrail.boundary = trail.boundary:onSerialize()
  else
    log('E', logTag, 'Trail has no boundary or invalid boundary object')
    return nil
  end

  local isValid, errorMsg = validateTrailPreset(serializedTrail)
  if not isValid then
    log('E', logTag, 'Invalid trail data: ' .. errorMsg)
    return nil
  end

  return serializedTrail
end

local function deserializeBoundaryPreset(data)
  if not data then
    log('E', logTag, 'No boundary preset data to deserialize')
    return nil
  end

  local isValid, errorMsg = validateBoundaryPreset(data)
  if not isValid then
    log('E', logTag, 'Invalid boundary preset data: ' .. errorMsg)
    return nil
  end

  local boundary = require('/lua/ge/extensions/gameplay/sites/zone')(nil, data.name)
  if boundary and boundary.onDeserialized then
    boundary:onDeserialized(data)
    return boundary
  else
    log('E', logTag, 'Failed to create boundary object for preset')
    return nil
  end
end

local function deserializePathnodePreset(data)
  if not data then
    log('E', logTag, 'No pathnode preset data to deserialize')
    return nil
  end

  local isValid, errorMsg = validatePathnodePreset(data)
  if not isValid then
    log('E', logTag, 'Invalid pathnode preset data: ' .. errorMsg)
    return nil
  end

  local path = {
    name = data.name or "",
    description = data.description or "",
    nodes = {}
  }
  for i, n in ipairs(data.nodes or {}) do
    table.insert(path.nodes, {
      name = n.name or ("Node " .. i),
      pos = vec3(n.position or {0,0,0}),
      rot = quat(n.rotation or {0,0,0,1}),
      radius = n.radius or 6.0,
      flags = n.flags or {}
    })
  end
  return path
end

local function deserializeTrailPreset(data)
  if not data then
    log('E', logTag, 'No trail preset data to deserialize')
    return nil
  end

  local isValid, errorMsg = validateTrailPreset(data)
  if not isValid then
    log('E', logTag, 'Invalid trail preset data: ' .. errorMsg)
    return nil
  end

  local trialObj = require('/lua/ge/extensions/editor/crawlEditor/trails')
  local trail = trialObj()

  trail:onDeserialized(data)

  if data.path then
    local p = {
      name = data.path.name or "Path",
      description = data.path.description or "",
      nodes = {}
    }
    for i, n in ipairs(data.path.nodes or {}) do
      table.insert(p.nodes, {
        name = n.name or ("Node " .. i),
        pos = vec3(n.position or {0,0,0}),
        rot = quat(n.rotation or {0,0,0,1}),
        radius = n.radius or 6.0,
        flags = n.flags or {}
      })
    end
    trail.path = p
  else
    log('E', logTag, 'No path data in trail preset')
    return nil
  end

  if data.boundary then
    local boundary = require('/lua/ge/extensions/gameplay/sites/zone')(nil, data.boundary.name or "Boundary")
    if boundary and boundary.onDeserialized then
      boundary:onDeserialized(data.boundary)
      trail.boundary = boundary
    else
      log('E', logTag, 'Failed to deserialize boundary for trail preset')
      return nil
    end
  else
    log('E', logTag, 'No boundary data in trail preset')
    return nil
  end

  return trail
end

function C:loadPresets()
  local filePresets = jsonReadFile(self.PRESETS_FILE)
  if filePresets then
    self.presets = filePresets
  else
    self:savePresets()
  end
end

function C:savePresets()
  self.presets.metadata.modified = os.date()

  local dir = string.match(self.PRESETS_FILE, "^(.*)/[^/]*$")
  if dir then
    FS:directoryCreate(dir)
  end

  local success = jsonWriteFile(self.PRESETS_FILE, self.presets, true)
  if success then
    log('I', logTag, 'Successfully saved presets to: ' .. self.PRESETS_FILE)
    return true, self.PRESETS_FILE
  else
    log('E', logTag, 'Failed to save presets to: ' .. self.PRESETS_FILE)
    return false, nil
  end
end

function C:saveBoundaryPreset(name, boundary)
  if not name or name == "" then
    log('E', logTag, 'Invalid boundary preset name')
    return false, nil
  end

  local serializedData = serializeBoundaryPreset(boundary)
  if not serializedData then
    log('E', logTag, 'Failed to serialize boundary preset: ' .. name)
    return false, nil
  end

  local preset = {
    name = name,
    category = self.PRESET_CATEGORIES.BOUNDARIES,
    data = serializedData,
    created = os.date(),
    modified = os.date()
  }

  self.presets.categories[self.PRESET_CATEGORIES.BOUNDARIES][name] = preset
  local success, filepath = self:savePresets()
  if success then
    log('I', logTag, 'Successfully saved boundary preset: ' .. name)
    return true, filepath
  else
    log('E', logTag, 'Failed to save boundary preset: ' .. name)
    return false, nil
  end
end

function C:savePathnodePreset(name, path)
  if not name or name == "" then
    log('E', logTag, 'Invalid pathnode preset name')
    return false, nil
  end

  local serializedData = serializePathnodePreset(path)
  if not serializedData then
    log('E', logTag, 'Failed to serialize pathnode preset: ' .. name)
    return false, nil
  end

  local preset = {
    name = name,
    category = self.PRESET_CATEGORIES.PATHNODES,
    data = serializedData,
    created = os.date(),
    modified = os.date()
  }

  self.presets.categories[self.PRESET_CATEGORIES.PATHNODES][name] = preset
  local success, filepath = self:savePresets()
  if success then
    log('I', logTag, 'Successfully saved pathnode preset: ' .. name)
    return true, filepath
  else
    log('E', logTag, 'Failed to save pathnode preset: ' .. name)
    return false, nil
  end
end

function C:saveTrailPreset(name, trail)
  if not name or name == "" then
    log('E', logTag, 'Invalid trail preset name')
    return false, nil
  end

  local serializedData = serializeTrailPreset(trail)
  if not serializedData then
    log('E', logTag, 'Failed to serialize trail preset: ' .. name)
    return false, nil
  end

  local preset = {
    name = name,
    category = self.PRESET_CATEGORIES.TRAILS,
    data = serializedData,
    created = os.date(),
    modified = os.date()
  }

  self.presets.categories[self.PRESET_CATEGORIES.TRAILS][name] = preset
  local success, filepath = self:savePresets()
  if success then
    log('I', logTag, 'Successfully saved trail preset: ' .. name)
    return true, filepath
  else
    log('E', logTag, 'Failed to save trail preset: ' .. name)
    return false, nil
  end
end

function C:loadBoundaryPreset(name)
  local preset = self.presets.categories[self.PRESET_CATEGORIES.BOUNDARIES][name]
  if not preset then
    log('E', logTag, 'Boundary preset not found: ' .. name)
    return nil, nil
  end

  local isValid, errorMsg = validatePresetData(preset, self.PRESET_CATEGORIES.BOUNDARIES)
  if not isValid then
    log('E', logTag, 'Invalid boundary preset data: ' .. errorMsg)
    return nil, nil
  end

  local boundary = deserializeBoundaryPreset(preset.data)
  if boundary then
    log('I', logTag, 'Successfully loaded boundary preset: ' .. name)
    return boundary, self.PRESETS_FILE
  else
    log('E', logTag, 'Failed to deserialize boundary preset: ' .. name)
    return nil, nil
  end
end

function C:loadPathnodePreset(name)
  local preset = self.presets.categories[self.PRESET_CATEGORIES.PATHNODES][name]
  if not preset then
    log('E', logTag, 'Pathnode preset not found: ' .. name)
    return nil, nil
  end

  local isValid, errorMsg = validatePresetData(preset, self.PRESET_CATEGORIES.PATHNODES)
  if not isValid then
    log('E', logTag, 'Invalid pathnode preset data: ' .. errorMsg)
    return nil, nil
  end

  local path = deserializePathnodePreset(preset.data)
  if path then
    log('I', logTag, 'Successfully loaded pathnode preset: ' .. name)
    return path, self.PRESETS_FILE
  else
    log('E', logTag, 'Failed to deserialize pathnode preset: ' .. name)
    return nil, nil
  end
end

function C:loadTrailPreset(name)
  local preset = self.presets.categories[self.PRESET_CATEGORIES.TRAILS][name]
  if not preset then
    log('E', logTag, 'Trail preset not found: ' .. name)
    return nil, nil
  end

  local isValid, errorMsg = validatePresetData(preset, self.PRESET_CATEGORIES.TRAILS)
  if not isValid then
    log('E', logTag, 'Invalid trail preset data: ' .. errorMsg)
    return nil, nil
  end

  local trail = deserializeTrailPreset(preset.data)
  if trail then
    log('I', logTag, 'Successfully loaded trail preset: ' .. name)
    return trail, self.PRESETS_FILE
  else
    log('E', logTag, 'Failed to deserialize trail preset: ' .. name)
    return nil, nil
  end
end

function C:deleteBoundaryPreset(name)
  if self.presets.categories[self.PRESET_CATEGORIES.BOUNDARIES][name] then
    self.presets.categories[self.PRESET_CATEGORIES.BOUNDARIES][name] = nil
    local success, filepath = self:savePresets()
    if success then
      log('I', logTag, 'Successfully deleted boundary preset: ' .. name)
      return true, filepath
    else
      log('E', logTag, 'Failed to delete boundary preset: ' .. name)
      return false, nil
    end
  end
  return false, nil
end

function C:deletePathnodePreset(name)
  if self.presets.categories[self.PRESET_CATEGORIES.PATHNODES][name] then
    self.presets.categories[self.PRESET_CATEGORIES.PATHNODES][name] = nil
    local success, filepath = self:savePresets()
    if success then
      log('I', logTag, 'Successfully deleted pathnode preset: ' .. name)
      return true, filepath
    else
      log('E', logTag, 'Failed to delete pathnode preset: ' .. name)
      return false, nil
    end
  end
  return false, nil
end

function C:deleteTrailPreset(name)
  if self.presets.categories[self.PRESET_CATEGORIES.TRAILS][name] then
    self.presets.categories[self.PRESET_CATEGORIES.TRAILS][name] = nil
    local success, filepath = self:savePresets()
    if success then
      log('I', logTag, 'Successfully deleted trail preset: ' .. name)
      return true, filepath
    else
      log('E', logTag, 'Failed to delete trail preset: ' .. name)
      return false, nil
    end
  end
  return false, nil
end

function C:getBoundaryPresets()
  local presetList = {}
  for name, preset in pairs(self.presets.categories[self.PRESET_CATEGORIES.BOUNDARIES]) do
    table.insert(presetList, {name = name, preset = preset})
  end
  return presetList
end

function C:getPathnodePresets()
  local presetList = {}
  for name, preset in pairs(self.presets.categories[self.PRESET_CATEGORIES.PATHNODES]) do
    table.insert(presetList, {name = name, preset = preset})
  end
  return presetList
end

function C:getTrailPresets()
  local presetList = {}
  for name, preset in pairs(self.presets.categories[self.PRESET_CATEGORIES.TRAILS]) do
    table.insert(presetList, {name = name, preset = preset})
  end
  return presetList
end

function C:getAllTrailComponents()
  local levelPath = getCurrentLevelCrawlPath()
  return saveSystem.getAllTrailComponents(levelPath)
end

function C:getAllBoundaryComponents()
  local levelPath = getCurrentLevelCrawlPath()
  return saveSystem.getAllBoundaryComponents(levelPath)
end

function C:getAllPathnodeComponents()
  local levelPath = getCurrentLevelCrawlPath()
  return saveSystem.getAllPathnodeComponents(levelPath)
end

function C:loadTrailComponent(id)
  local levelPath = getCurrentLevelCrawlPath()
  return saveSystem.loadTrailComponent(id, levelPath)
end

function C:loadBoundaryComponent(id)
  local levelPath = getCurrentLevelCrawlPath()
  return saveSystem.loadBoundaryComponent(id, levelPath)
end

function C:loadPathnodeComponent(id)
  local levelPath = getCurrentLevelCrawlPath()
  return saveSystem.loadPathnodeComponent(id, levelPath)
end

function C:saveTrailComponent(name, trail)
  if not name or name == "" then
    log('E', logTag, 'Invalid trail component name')
    return false, nil
  end

  if trail then
    trail.name = name
  end

  local success = saveSystem.saveTrailComponent(trail)
  if success then
    log('I', logTag, 'Successfully saved trail component: ' .. name)
    return true, success
  else
    log('E', logTag, 'Failed to save trail component: ' .. name)
    return false, nil
  end
end

function C:saveBoundaryComponent(name, boundary)
  if not name or name == "" then
    log('E', logTag, 'Invalid boundary component name')
    return false, nil
  end

  if boundary then
    boundary.name = name
  end

  local success = saveSystem.saveBoundaryComponent(boundary)
  if success then
    log('I', logTag, 'Successfully saved boundary component: ' .. name)
    return true, success
  else
    log('E', logTag, 'Failed to save boundary component: ' .. name)
    return false, nil
  end
end

function C:savePathnodeComponent(name, path)
  if not name or name == "" then
    log('E', logTag, 'Invalid pathnode component name')
    return false, nil
  end

  if path then
    path.name = name
  end

  local success = saveSystem.savePathnodeComponent(path)
  if success then
    log('I', logTag, 'Successfully saved pathnode component: ' .. name)
    return true, success
  else
    log('E', logTag, 'Failed to save pathnode component: ' .. name)
    return false, nil
  end
end

function C:deleteTrailComponent(id)
  return saveSystem.deleteTrailComponent(id)
end

function C:deleteBoundaryComponent(id)
  return saveSystem.deleteBoundaryComponent(id)
end

function C:deletePathnodeComponent(id)
  return saveSystem.deletePathnodeComponent(id)
end

function C:exportPreset(category, name, filepath)
  local preset = self.presets.categories[category] and self.presets.categories[category][name]
  if not preset then
    log('E', logTag, 'Preset not found: ' .. category .. '/' .. name)
    return false, nil
  end

  local success = jsonWriteFile(filepath, preset, true)
  if success then
    log('I', logTag, 'Successfully exported preset to: ' .. filepath)
    return true, filepath
  else
    log('E', logTag, 'Failed to export preset to: ' .. filepath)
    return false, nil
  end
end

function C:importPreset(filepath, category)
  local data = jsonReadFile(filepath)
  if not data then
    log('E', logTag, 'Failed to read preset file: ' .. filepath)
    return false, nil
  end

  local isValid, errorMsg = validatePresetData(data, category)
  if not isValid then
    log('E', logTag, 'Invalid preset data: ' .. errorMsg)
    return false, nil
  end

  self.presets.categories[category][data.name] = data
  local success, presetsFilepath = self:savePresets()
  if success then
    log('I', logTag, 'Successfully imported preset from: ' .. filepath)
    return true, presetsFilepath
  else
    log('E', logTag, 'Failed to import preset from: ' .. filepath)
    return false, nil
  end
end

function C:getShowSaveBoundaryDialog() return self.showSaveBoundaryDialog end
function C:setShowSaveBoundaryDialog(show) self.showSaveBoundaryDialog = show end
function C:getShowSavePathnodeDialog() return self.showSavePathnodeDialog end
function C:setShowSavePathnodeDialog(show) self.showSavePathnodeDialog = show end
function C:getShowSaveTrailDialog() return self.showSaveTrailDialog end
function C:setShowSaveTrailDialog(show) self.showSaveTrailDialog = show end
function C:getShowPresetManager() return self.showPresetManager end
function C:setShowPresetManager(show)
  self.showPresetManager = show
  self.showPresetManagerPtr[0] = show
end
function C:getShowPresetManagerPtr() return self.showPresetManagerPtr end
function C:getBoundaryPresetName() return self.boundaryPresetName end
function C:getPathnodePresetName() return self.pathnodePresetName end
function C:getTrailPresetName() return self.trailPresetName end

function C:drawMenu(crawlData, trails, waypoints)
  self.crawlData = crawlData
  self.trails = trails
  self.waypoints = waypoints
  if im.BeginMenu("Trail Components") then
    local trailComponents = self:getAllTrailComponents()
    if #trailComponents == 0 then
      im.TextDisabled("No trail components available")
    else
      for _, component in ipairs(trailComponents) do
        if im.MenuItem1(component.name) then
          local loadedTrail = self:loadTrailComponent(component.id)
                      if loadedTrail then
              table.insert(crawlData.trails, loadedTrail)
              trails:setSelectedTrailIndex(#crawlData.trails)
              waypoints:setSelectedPathnodeIndex(1)
              if #loadedTrail.path.pathnodes.sorted > 0 then
                waypoints:selectPathnode(1)
              end
            else
              log('E', logTag, 'Failed to load trail component: ' .. component.name)
            end
        end
      end
    end
    im.Separator()
    if im.MenuItem1("Save Current Trail as Component...") then
      self:setShowSaveTrailDialog(true)
    end
    im.EndMenu()
  end

  im.Separator()

  if im.BeginMenu("Boundary Components") then
    local boundaryComponents = self:getAllBoundaryComponents()
    if #boundaryComponents == 0 then
      im.TextDisabled("No boundary components available")
    else
      for _, component in ipairs(boundaryComponents) do
        if im.MenuItem1(component.name) then
          if trails:getSelectedTrailIndex() > 0 and trails:getSelectedTrailIndex() <= #crawlData.trails then
            local loadedBoundary = self:loadBoundaryComponent(component.id)
            if loadedBoundary then
              crawlData.trails[trails:getSelectedTrailIndex()].boundary = loadedBoundary
            else
              log('E', logTag, 'Failed to load boundary component: ' .. component.name)
            end
          end
        end
      end
    end
    im.Separator()
    if im.MenuItem1("Save Current Boundary as Component...") then
      self:setShowSaveBoundaryDialog(true)
    end
    im.EndMenu()
  end

  if im.BeginMenu("Pathnode Components") then
    local pathnodeComponents = self:getAllPathnodeComponents()
    if #pathnodeComponents == 0 then
      im.TextDisabled("No pathnode components available")
    else
      for _, component in ipairs(pathnodeComponents) do
        if im.MenuItem1(component.name) then
          if trails:getSelectedTrailIndex() > 0 and trails:getSelectedTrailIndex() <= #crawlData.trails then
            local loadedPath = self:loadPathnodeComponent(component.id)
            if loadedPath then
              crawlData.trails[trails:getSelectedTrailIndex()].path = loadedPath
              waypoints:setSelectedPathnodeIndex(1)
              if #loadedPath.pathnodes.sorted > 0 then
                waypoints:selectPathnode(1)
              end
            else
              log('E', logTag, 'Failed to load pathnode component: ' .. component.name)
            end
          end
        end
      end
    end
    im.Separator()
    if im.MenuItem1("Save Current Pathnodes as Component...") then
      self:setShowSavePathnodeDialog(true)
    end
    im.EndMenu()
  end

  im.Separator()
  if im.MenuItem1("Manage Components...") then
    self:setShowPresetManager(true)
  end
end

function C:drawDialogs()
  if self:getShowSaveBoundaryDialog() then
    local showBoundaryDialogPtr = im.BoolPtr(self:getShowSaveBoundaryDialog())
    if im.Begin("Save Boundary Component", showBoundaryDialogPtr, nil) then
      im.Text("Enter a name for the boundary component:")
      im.InputText("##boundaryPresetName", self:getBoundaryPresetName(), 256)

      im.NewLine()
              if im.Button("Save") then
          local name = ffi.string(self:getBoundaryPresetName())
          if name and name ~= "" then
            local crawlData = self.crawlData
            local trails = self.trails
            if crawlData and trails:getSelectedTrailIndex() > 0 and trails:getSelectedTrailIndex() <= #crawlData.trails then
              local trail = crawlData.trails[trails:getSelectedTrailIndex()]
              if trail.boundary then
                local success, _ = self:saveBoundaryComponent(name, trail.boundary)
                if success then
                  log('I', logTag, 'Successfully saved boundary component: ' .. name)
                else
                  log('E', logTag, 'Failed to save boundary component: ' .. name)
                end
              end
            end
            self:setShowSaveBoundaryDialog(false)
            ffi.copy(self:getBoundaryPresetName(), "")
          end
        end
      im.SameLine()
      if im.Button("Cancel") then
        self:setShowSaveBoundaryDialog(false)
        ffi.copy(self:getBoundaryPresetName(), "")
      end
    end
    im.End()

    if not showBoundaryDialogPtr[0] then
      self:setShowSaveBoundaryDialog(false)
    end
  end

  if self:getShowSavePathnodeDialog() then
    local showPathnodeDialogPtr = im.BoolPtr(self:getShowSavePathnodeDialog())
    if im.Begin("Save Pathnode Component", showPathnodeDialogPtr, nil) then
      im.Text("Enter a name for the pathnode component:")
      im.InputText("##pathnodePresetName", self:getPathnodePresetName(), 256)

      im.NewLine()
              if im.Button("Save") then
          local name = ffi.string(self:getPathnodePresetName())
          if name and name ~= "" then
            local crawlData = self.crawlData
            local trails = self.trails
            if crawlData and trails:getSelectedTrailIndex() > 0 and trails:getSelectedTrailIndex() <= #crawlData.trails then
              local trail = crawlData.trails[trails:getSelectedTrailIndex()]
              if trail.path then
                local success, _ = self:savePathnodeComponent(name, trail.path)
                if success then
                  log('I', logTag, 'Successfully saved pathnode component: ' .. name)
                else
                  log('E', logTag, 'Failed to save pathnode component: ' .. name)
                end
              end
            end
            self:setShowSavePathnodeDialog(false)
            ffi.copy(self:getPathnodePresetName(), "")
          end
        end
      im.SameLine()
      if im.Button("Cancel") then
        self:setShowSavePathnodeDialog(false)
        ffi.copy(self:getPathnodePresetName(), "")
      end
    end
    im.End()

    if not showPathnodeDialogPtr[0] then
      self:setShowSavePathnodeDialog(false)
    end
  end

  if self:getShowSaveTrailDialog() then
    local showTrailDialogPtr = im.BoolPtr(self:getShowSaveTrailDialog())
    if im.Begin("Save Trail Component", showTrailDialogPtr, nil) then
      im.Text("Enter a name for the trail component:")
      im.InputText("##trailPresetName", self:getTrailPresetName(), 256)

      im.NewLine()
              if im.Button("Save") then
          local name = ffi.string(self:getTrailPresetName())
          if name and name ~= "" then
            local crawlData = self.crawlData
            local trails = self.trails
            if crawlData and trails:getSelectedTrailIndex() > 0 and trails:getSelectedTrailIndex() <= #crawlData.trails then
              local trail = crawlData.trails[trails:getSelectedTrailIndex()]
              local success, _ = self:saveTrailComponent(name, trail)
              if success then
                log('I', logTag, 'Successfully saved trail component: ' .. name)
              else
                log('E', logTag, 'Failed to save trail component: ' .. name)
              end
            end
            self:setShowSaveTrailDialog(false)
            ffi.copy(self:getTrailPresetName(), "")
          end
        end
      im.SameLine()
      if im.Button("Cancel") then
        self:setShowSaveTrailDialog(false)
        ffi.copy(self:getTrailPresetName(), "")
      end
    end
    im.End()

    if not showTrailDialogPtr[0] then
      self:setShowSaveTrailDialog(false)
    end
  end

  if self:getShowPresetManager() then
    if im.Begin("Component Manager", self:getShowPresetManagerPtr(), nil, im.ImVec2(600, 400)) then
      im.Text("Trail Components")
      im.Separator()
      local trailComponents = self:getAllTrailComponents()
      if #trailComponents == 0 then
        im.TextDisabled("No trail components")
      else
        for _, component in ipairs(trailComponents) do
          im.Text(component.name)
          im.SameLine()
          if im.Button("Delete##trail" .. component.id) then
            self:deleteTrailComponent(component.id)
          end
        end
      end

      im.NewLine()
      im.Separator()
      im.NewLine()

      im.Text("Boundary Components")
      im.Separator()
      local boundaryComponents = self:getAllBoundaryComponents()
      if #boundaryComponents == 0 then
        im.TextDisabled("No boundary components")
      else
        for _, component in ipairs(boundaryComponents) do
          im.Text(component.name)
          im.SameLine()
          if im.Button("Delete##boundary" .. component.id) then
            self:deleteBoundaryComponent(component.id)
          end
        end
      end

      im.NewLine()
      im.Separator()
      im.NewLine()

      im.Text("Pathnode Components")
      im.Separator()
      local pathnodeComponents = self:getAllPathnodeComponents()
      if #pathnodeComponents == 0 then
        im.TextDisabled("No pathnode components")
      else
        for _, component in ipairs(pathnodeComponents) do
          im.Text(component.name)
          im.SameLine()
          if im.Button("Delete##pathnode" .. component.id) then
            self:deletePathnodeComponent(component.id)
          end
        end
      end
    end
    im.End()

    if not self:getShowPresetManagerPtr()[0] then
      self.showPresetManager = false
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