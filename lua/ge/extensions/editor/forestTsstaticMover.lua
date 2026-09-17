-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local im = ui_imgui

local toolWindowName = "forestTsstaticMover"
local toolName = "Forest TSStatic Mover"

-- UI state
local selectCreated   = im.BoolPtr(false)
local useSameMesh     = im.BoolPtr(true)
local putInNewFolder  = im.BoolPtr(true)

local lastError = nil

-- Helpers
local function validObj(id) return id and scenetree.findObjectById(id) end

local function getForest()
  return core_forest and core_forest.getForestObject and core_forest.getForestObject()
end

local function getForestData()
  local f = getForest()
  return f and f:getData() or nil
end

local function avgVec3(v)
  if not v then return nil end
  if type(v) == "cdata" and v.x then
    return (v.x + v.y + v.z) / 3
  end
  return tonumber(v)
end

local function getIdsOfClass(className)
  local out = {}
  local objects = scenetree.findClassObjects(className) or {}
  for _, v in ipairs(objects) do
    local o = scenetree.findObject(v)
    if o and o.getId then table.insert(out, o:getId()) end
  end
  return out
end

-- Edit mode helpers
local function isObjectMode()
  return editor and editor.editMode and editor.editModes and editor.editModes.objectSelect
     and editor.editMode.displayName == editor.editModes.objectSelect.displayName
end

local function isForestMode()
  return editor and editor.editMode and editor.editModes and editor.editModes.forestToolsEditMode
     and editor.editMode.displayName == editor.editModes.forestToolsEditMode.displayName
end

-- Selection helpers
local function getSelectedTSStatics()
  local out = {}
  if editor.selection and editor.selection.object then
    for _, id in ipairs(editor.selection.object) do
      local o = scenetree.findObjectById(id)
      if o and o.getClassName and o:getClassName() == "TSStatic" then
        table.insert(out, id)
      end
    end
  end
  return out
end

local function getSelectedForestItems()
  return (editor.selection and editor.selection.forestItem) or {}
end

-- Shape name display
local function getSelectedTSStaticShape()
  local tsIds = getSelectedTSStatics()
  if #tsIds == 0 then return nil end
  local o = scenetree.findObjectById(tsIds[#tsIds])
  if not o then return nil end
  local shp = o:getField("shapeName", 0)
  return (shp ~= "" and shp) or nil
end

local function getSelectedForestItemShape()
  local items = getSelectedForestItems()
  if not items or #items == 0 then return nil end
  local it = items[#items]
  local d = it and it.getData and it:getData() or nil
  local shp = d and d.getShapeFile and tostring(d:getShapeFile()) or nil
  return (shp and shp ~= "" and shp) or nil
end

local function expandTSStaticSelectionSameMesh(tsIds)
  if not tsIds or #tsIds == 0 then return tsIds end
  local ref = scenetree.findObjectById(tsIds[1])
  if not ref then return tsIds end
  local refShape = ref:getField("shapeName", 0)
  if not refShape or refShape == "" then return tsIds end

  local all = getIdsOfClass("TSStatic")
  local out = {}
  for _, id in ipairs(all) do
    local o = scenetree.findObjectById(id)
    if o and o:getField("shapeName", 0) == refShape then
      table.insert(out, id)
    end
  end
  return out
end

local function expandForestSelectionSameMesh(forestData, items)
  if not forestData or not items or #items == 0 then return items end
  local ref = items[1]
  local refData = ref and ref.getData and ref:getData() or nil
  local refId = refData and refData.getId and refData:getId() or nil
  if not refId then return items end

  local out = {}
  for _, it in ipairs(forestData:getItems()) do
    local d = it:getData()
    if d and d.getId and d:getId() == refId then
      table.insert(out, it)
    end
  end
  return out
end

-- ForestItemData management
local function findForestItemDataByShapeFile(shapeFile)
  if not shapeFile or shapeFile == "" then return nil end
  local ids = scenetree.findClassObjects("ForestItemData") or {}
  for _, nameOrId in ipairs(ids) do
    local obj = scenetree.findObject(nameOrId)
    if obj and obj.shapeFile and tostring(obj.shapeFile) == shapeFile then
      return obj
    end
  end
  return nil
end

local function createForestItemDataForShape(shapeFile)
  if not editor.createDataBlock then return nil end
  if not shapeFile or shapeFile == "" then return nil end

  local baseName = shapeFile:match("([^/\\]+)%.%w+$") or "ForestItem"
  local name = Sim.getUniqueName(baseName)

  local levelPath = editor.levelPath
  if not levelPath then
    levelPath = path.split(getMissionFilename())
  end
  local dbFile = levelPath .. "art/forest/managedItemData.json"

  local id = editor.createDataBlock(name, "ForestItemData", nil, dbFile)
  local obj = scenetree.findObjectById(id)
  if obj then
    obj:setField("shapeFile", "", shapeFile)
    obj:setInternalName(name)
    obj:setName(name)
    editor.setDirty()
    if editor_forestEditor and editor_forestEditor.refreshForestItemDataList then
      editor_forestEditor.refreshForestItemDataList()
    end
  end
  return obj
end

-- Capture Data for undo/redo
local function captureTSStaticData(ids)
  local t = {}
  for _, id in ipairs(ids) do
    local o = scenetree.findObjectById(id)
    if o then
      table.insert(t, {
        id = id,
        memento = editor.saveSimObjectMemento(o),
        transform = o:getTransform(),
        scale = o:getScale(),
        shapeName = o:getField("shapeName", 0),
        parentGroup = tonumber(o:getField("parentGroup", 0))
      })
    end
  end
  return t
end

local function captureForestData(items)
  local t = {}
  for _, it in ipairs(items) do
    local d = it:getData()
    table.insert(t, {
      transform = it:getTransform(),
      scale = it:getScale(),
      itemDataId = d and d.getId and d:getId() or nil,
      shapeFile = d and tostring(d:getShapeFile()) or nil,
      uid = it.getUid and it:getUid() or nil,
    })
  end
  return t
end

-- Create targets
local function createTSStaticsFromForestData(params, presetIds, presetGroupId)
  local createdIds = {}
  local grp = scenetree.MissionGroup

  -- optional folder group
  local targetGroup = grp
  if params.putInNewFolder then
    if presetGroupId then SimObject.setForcedId(presetGroupId) end
    local g = createObject("SimGroup")
    g:registerObject(Sim.getUniqueName("MovedForestToTSStatic"))
    grp:addObject(g)
    targetGroup = g
    params.createdGroupId = g:getId()
  end

  for i, fs in ipairs(params.forestData) do
    local shape = fs.shapeFile
    if not shape or shape == "" then goto continue end

    if presetIds and presetIds[i] then SimObject.setForcedId(presetIds[i]) end
    local obj = createObject("TSStatic")

    obj:setField("shapeName", 0, shape)
    obj:registerObject("") -- we need to register first, then add object to group, otherwise it breaks
    targetGroup:addObject(obj)
    obj:setTransform(fs.transform)

    local s = fs.scale
    if type(s) == "number" then
      obj:setScale(vec3(s, s, s))
    elseif type(s) == "cdata" and s.x then
      obj:setScale(vec3(s.x, s.y, s.z))
    else
      obj:setScale(vec3(1,1,1))
    end

    table.insert(createdIds, obj:getId())
    ::continue::
  end

  if params.selectCreated and #createdIds > 0 then
    editor.clearObjectSelection()
    editor.selection.object = {}
    for _, id in ipairs(createdIds) do table.insert(editor.selection.object, id) end
    extensions.hook("onEditorObjectSelectionChanged")
  end

  return createdIds, params.createdGroupId
end

local function createForestItemsFromTSStaticData(forestData, params)
  local createdItems = {}
  for _, ts in ipairs(params.tsData) do
    local shapeFile = ts.shapeName
    if not shapeFile or shapeFile == "" then goto continue end

    local itemData = findForestItemDataByShapeFile(shapeFile)
    if not itemData then
      itemData = createForestItemDataForShape(shapeFile)
    end
    if not itemData then goto continue end

    local forestScale = avgVec3(ts.scale) or 1.0
    local item = forestData:createNewItem(itemData, ts.transform, forestScale)
    table.insert(createdItems, item)
    ::continue::
  end

  editor.forestDirty = true
  editor.setDirty()
  worldEditorCppApi.rebuildForestManagerInstanceData()

  if params.selectCreated and #createdItems > 0 then
    if editor_forestEditor and editor_forestEditor.selectForestItems then
      editor_forestEditor.selectForestItems(createdItems)
    else
      editor.selection.forestItem = createdItems
      extensions.hook("onEditorObjectSelectionChanged")
    end
  end

  return createdItems
end

-- Delete sources
local function deleteTSStatics(ids)
  for _, id in ipairs(ids) do
    if validObj(id) then editor.deleteObject(id) end
  end
end

local function deleteForestItems(forestData, items)
  for _, it in ipairs(items) do
    if it then editor.removeForestItem(forestData, it) end
  end
  editor.forestDirty = true
  editor.setDirty()
  worldEditorCppApi.rebuildForestManagerInstanceData()
end

-- Undo / Redo
local function actionUndo(data)
  local forestData = getForestData()

  -- remove created TSStatics
  if data.createdTSIds then
    for _, id in ipairs(data.createdTSIds) do
      if validObj(id) then editor.deleteObject(id) end
    end
  end

  -- remove created group (folder) if any
  if data.createdGroupId and validObj(data.createdGroupId) then
    editor.deleteObject(data.createdGroupId)
  end

  -- remove created forest items
  if data.createdForestItems and forestData then
    deleteForestItems(forestData, data.createdForestItems)
  end

  -- restore deleted TSStatics (from mementos)
  if data.deletedTSStatics and #data.deletedTSStatics > 0 then
    local root = scenetree.MissionGroup
    for _, ts in ipairs(data.deletedTSStatics) do
      if ts.id then SimObject.setForcedId(ts.id) end
      local obj = editor.restoreSimObjectMemento(ts.memento)

      local pg = ts.parentGroup and scenetree.findObjectById(ts.parentGroup) or nil
      (pg or root):addObject(obj)

      obj:setTransform(ts.transform)
      obj:setScale(ts.scale)
      obj:setField("shapeName", 0, ts.shapeName or "")
    end
  end

  -- restore deleted forest items from Data
  if data.deletedForestItems and #data.deletedForestItems > 0 and forestData then
    local restored = {}
    for _, fs in ipairs(data.deletedForestItems) do
      local itemData = fs.itemDataId and scenetree.findObjectById(fs.itemDataId) or nil
      if not itemData and fs.shapeFile and fs.shapeFile ~= "" then
        itemData = findForestItemDataByShapeFile(fs.shapeFile) or createForestItemDataForShape(fs.shapeFile)
      end
      if itemData then
        local item = forestData:createNewItem(itemData, fs.transform, fs.scale)
        table.insert(restored, item)
      end
    end

    editor.forestDirty = true
    editor.setDirty()
    worldEditorCppApi.rebuildForestManagerInstanceData()

    if data.selectCreated and #restored > 0 then
      if editor_forestEditor and editor_forestEditor.selectForestItems then
        editor_forestEditor.selectForestItems(restored)
      else
        editor.selection.forestItem = restored
        extensions.hook("onEditorObjectSelectionChanged")
      end
    end
  end

  editor.clearObjectSelection()
end

local function actionRedo(data)
  lastError = nil
  local forestData = getForestData()
  if not forestData then
    lastError = "No Forest object/data present in this level."
    return
  end

  data.createdTSIds = nil
  data.createdForestItems = nil
  data.createdGroupId = data.createdGroupId -- keep for forced id redo

  if data.direction == "TSToForest" then
    data.createdForestItems = createForestItemsFromTSStaticData(forestData, data)
    deleteTSStatics(data.deletedTSStaticIds)

  elseif data.direction == "ForestToTS" then
    data.createdTSIds, data.createdGroupId = createTSStaticsFromForestData(data, data.createdTSIds, data.createdGroupId)
    deleteForestItems(forestData, data.deletedForestItemsLive)
  end
end

-- Run actions
local function runTSToForest()
  lastError = nil

  if not isObjectMode() then
    lastError = "Switch to Object Select mode to move TSStatic -> Forest."
    return
  end

  local forestData = getForestData()
  if not forestData then
    lastError = "No Forest object/data present. Create a Forest first."
    return
  end

  local tsIds = getSelectedTSStatics()
  if not tsIds or #tsIds == 0 then
    lastError = "Select one or more TSStatic objects first."
    return
  end

  if useSameMesh[0] then
    tsIds = expandTSStaticSelectionSameMesh(tsIds)
  end

  local tsData = captureTSStaticData(tsIds)
  if #tsData == 0 then
    lastError = "No valid TSStatic objects."
    return
  end

  local actionData = {
    direction = "TSToForest",
    tsData = deepcopy(tsData),
    deletedTSStaticIds = deepcopy(tsIds),
    deletedTSStatics = deepcopy(tsData),
    selectCreated = selectCreated[0],
    createdForestItems = nil,
    putInNewFolder = false, -- not applicable in this direction
    createdGroupId = nil
  }
  editor.history:commitAction("Move TSStatic -> Forest", actionData, actionUndo, actionRedo)
end

local function runForestToTS()
  lastError = nil

  if not isForestMode() then
    lastError = "Switch to Forest Tools mode to move ForestItems -> TSStatic."
    return
  end

  local forestDataObj = getForestData()
  if not forestDataObj then
    lastError = "No Forest object/data present. Create a Forest first."
    return
  end

  local items = getSelectedForestItems()
  if not items or #items == 0 then
    lastError = "Select one or more ForestItems first."
    return
  end

  if useSameMesh[0] then
    items = expandForestSelectionSameMesh(forestDataObj, items)
  end

  local forestCaptured = captureForestData(items)
  if #forestCaptured == 0 then
    lastError = "No valid Forest items."
    return
  end

  local deletedForestItemsLive = {}
  for _, it in ipairs(items) do table.insert(deletedForestItemsLive, it) end

  local actionData = {
    direction = "ForestToTS",
    forestData = deepcopy(forestCaptured),
    deletedForestItems = deepcopy(forestCaptured),
    deletedForestItemsLive = deletedForestItemsLive,
    selectCreated = selectCreated[0],
    createdTSIds = nil,
    putInNewFolder = putInNewFolder[0],
    createdGroupId = nil
  }
  editor.history:commitAction("Move Forest -> TSStatic", actionData, actionUndo, actionRedo)
end

-- UI
local function onEditorGui()
  if editor.beginWindow(toolWindowName, toolName) then
    if getForest() then
      im.TextUnformatted("Move instances between Forest and TSStatic.")
      im.Separator()

      local modeStr = (editor.editMode and editor.editMode.displayName) and editor.editMode.displayName or "unknown"
      im.TextUnformatted("Edit mode: " .. tostring(modeStr))

      local shape = nil
      if isObjectMode() then
        shape = getSelectedTSStaticShape()
        im.TextUnformatted("Selected TSStatic shape: " .. tostring(shape or "-none-"))
      elseif isForestMode() then
        shape = getSelectedForestItemShape()
        im.TextUnformatted("Selected ForestItem shape: " .. tostring(shape or "-none-"))
      else
        im.TextUnformatted("Selected shape: - (switch to Object Select or Forest Tools)")
      end

      im.Separator()
      im.Checkbox("Select Moved", selectCreated)
      im.Checkbox("Move all instances of selected shape", useSameMesh)
      im.Checkbox("Put created TSStatics into new folder (SimGroup)", putInNewFolder)
      im.tooltip("Only applies to ForestItems -> TSStatic. Forest items do not use SimGroups.")

      im.Separator()

      -- Buttons gated by edit mode
      if not isForestMode() then im.BeginDisabled() end
      if im.Button("Move selected ForestItems -> TSStatic") then
        runForestToTS()
      end
      if not isForestMode() then
        im.EndDisabled()
        im.SameLine()
        im.TextColored(im.ImVec4(1,1,0,1), "Forest Tools mode required")
      end

      if not isObjectMode() then im.BeginDisabled() end
      if im.Button("Move selected TSStatic -> ForestItems") then
        runTSToForest()
      end
      if not isObjectMode() then
        im.EndDisabled()
        im.SameLine()
        im.TextColored(im.ImVec4(1,1,0,1), "Object Select mode required")
      end

      if lastError then
        im.Separator()
        im.TextColored(im.ImVec4(1,1,0,1), lastError)
      end
    else
      im.TextColored(im.ImVec4(1,1,0,1), "Forest data is missing in the level")
    end
  end
  editor.endWindow()
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  editor.addWindowMenuItem(toolName, onWindowMenuItem)
  editor.registerWindow(toolWindowName, im.ImVec2(560, 260))
end

M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized
M.dependencies = {"core_forest"}
return M
