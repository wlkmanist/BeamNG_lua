-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = 'asset_migration_tool'
local imgui = ui_imgui
local ffi = require('ffi')
local imUtils = require('ui/imguiUtils')
local toolWindowName = "assetMigrationTool"
local deleteSelectionModalWndName = "assetMigrationDeleteSelection"
local newPathNotSetMsgDlg = "assetMigrationNewPathNotSetMsgDlg"
local migrationDlg = "migrationDlg"
local migrationMessage = ""
local migrationProgress = 0
local migrationDone = true
local stopMigration = false
local assetRecords = {}
local inputTextOld = imgui.ArrayChar(2048)
local inputTextNew = imgui.ArrayChar(2048)
local jsonTable = {}
local recordIndex = 0
local del = imgui.BoolPtr(false)
local listWasModified = false
local searchFilter = imgui.ImGuiTextFilter()
local selectRecordBoolPtr = imgui.BoolPtr(false)
local selectedIndices = {}
local showOnlyDeleted = imgui.BoolPtr(false)
local visibleRecordCount = 0
local lastPath = "/"
local newPathNotSet = "NOT_SET"
local newPathNotSetForThisOldPath = ""
local duplicateOldPaths = {}
local forceFilterNow = false

local assetExtensions = {} --= worldEditorCppApi.getAssetExtensions()

local function checkForDuplicateRecords()
  local uniqueKeys = {}
  duplicateOldPaths = {}
  local oldPaths = {}

  for _, record in ipairs(assetRecords) do
    if type(record.old) == "table" then
      oldPaths = record.old
    else
      oldPaths = {record.old}
    end
    record.duplicated = false
    for _, path in ipairs(oldPaths) do
      if not uniqueKeys[path] then
        uniqueKeys[path] = true
      else
        record.duplicated = true
        if not duplicateOldPaths[path] then
          duplicateOldPaths[path] = true
        end
      end
    end
  end
end

local function loadList()
  jsonTable = {}
  jsonTable = jsonReadFile("/assets/asset_migration.json")

  if jsonTable then
    assetRecords = jsonTable["remapping"]
  else
    assetRecords = {}
  end

  checkForDuplicateRecords()

  listWasModified = false
  selectedIndices = {}
end

local function saveList()
  jsonTable["remapping"] = deepcopy(assetRecords)
  -- remove some temp fields before saving
  for _, record in ipairs(jsonTable["remapping"]) do
    if record.new == newPathNotSet then
      local oldPath
      if type(record.old) == "table" then
        if #record.old then oldPath = record.old[1] end
      else
        oldPath = record.old
      end
      editor.logError("You need to set the new file path for asset migration record of old path: '" .. oldPath .. "'")
      newPathNotSetForThisOldPath = oldPath
      return false
    end
    record.timestampStr = nil
    record.visible = nil
    record.duplicated = nil
  end
  jsonWriteFile("/assets/asset_migration.json", jsonTable, true)
  listWasModified = false
  return true
end

local function filterList()
  local isFilterActive = imgui.ImGuiTextFilter_IsActive(searchFilter)
  local hasOldMatch
  visibleRecordCount = 0

  for _, record in ipairs(assetRecords) do
    if isFilterActive then
      hasOldMatch = false
      local str = imgui.TextFilter_GetInputBuf(searchFilter)
      if ffi.string(str) == ":dupes" then
        if record.duplicated then
          record.visible = true
          visibleRecordCount = visibleRecordCount + 1
        else
          record.visible = false
        end
      else
        if type(record.old) == "table" then
          for i = 1, #record.old do
            if imgui.ImGuiTextFilter_PassFilter(searchFilter, record.old[i]) then
              hasOldMatch = true
              break
            end
          end
        else
          if imgui.ImGuiTextFilter_PassFilter(searchFilter, record.old) then
            hasOldMatch = true
          end
        end

        if hasOldMatch or imgui.ImGuiTextFilter_PassFilter(searchFilter, record.new) or (showOnlyDeleted[0] and record.wasDeleted) then
          record.visible = true
          visibleRecordCount = visibleRecordCount + 1
        else
          record.visible = false
        end
      end
    else
      record.visible = true
      visibleRecordCount = visibleRecordCount + 1
    end
  end
end

local function checkIfAlreadyMigrated(path)
  for _, record in ipairs(assetRecords) do
    if record.old == path then
      return true
    end
    if type(record.old) == "table" then
      for _, v in ipairs(record.old) do
        if v == path then return true end
      end
    end
  end

  return false
end

local function isGamePathSameAsUserPath()
  -- TODO: use Torque3d::PathUtils::noUserPath, expose it to Lua
  return FS:getGamePath() == FS:getUserPath()
end

--TODO
local function checkModDbForPath(path)
  core_online.download('http://modutils/modgrep/grep.php', function(request)
    if request.responseData == nil then
      log('E', '', 'Server Error')
      log('E', '', 'url = '..tostring(request.uri))
      log('E', '', 'responseBuf = '..tostring(request.responseBuffer))
      return
    end
    print(dumps(request.responseData) )
  end, {
    search = path,
    outputJson = "1",
    filetype = "lua"
  }, "POST", nil)
end

local function getFirstOldPath(record)
  if type(record.old) == "table" then
    return record.old[1] or ""
  end

  return record.old
end

local function createAssetInfo(path)
  local foundExt = nil

  -- convert extension of path to lowercase so it matches with the assetExtensions' lowercase
  local lowerPath = string.lower(path)

  for _, ext in ipairs(assetExtensions) do
    if string.endswith(lowerPath, "." .. ext) then
      foundExt = ext
      break
    end
  end

  -- not a supported asset extension
  if not foundExt then return end

  local json = nil
  local assetInfoPath

  -- check if the json asset info file exists
  -- get path without extension
  assetInfoPath = path .. ".asset"
  if not FS:fileExists(assetInfoPath) then
    -- create an empty json if nothing exists yet
    json = {}
    json.uuid = string.gsub(worldEditorCppApi.generateUUID(), "-", "") -- remove the hyphen, continuous UUID is easier to select in text
    json.version = 1
    jsonWriteFile(assetInfoPath, json, true)
  end
end

local function createAssetInfoForFolder(folderPath)
  local files = FS:findFiles(folderPath, "*.*", -1, true, false)

  editor.log("Creating asset info files for " .. #files .. " in " .. folderPath .. "...")

  for _, path in ipairs(files) do
    createAssetInfo(path)
  end
end

local function createAssetInfoForAllAssetsJob(job)
  createAssetInfoForFolder("/art")
  createAssetInfoForFolder("/core")
  createAssetInfoForFolder("/assets")
  createAssetInfoForFolder("/campaigns")
  createAssetInfoForFolder("/flowgraphEditor")
  createAssetInfoForFolder("/gameplay")
  createAssetInfoForFolder("/levels")
  createAssetInfoForFolder("/projects")
  createAssetInfoForFolder("/protected")
  createAssetInfoForFolder("/renderer")
  createAssetInfoForFolder("/replays")
  createAssetInfoForFolder("/shaders")
  createAssetInfoForFolder("/tech")
  createAssetInfoForFolder("/trackEditor")
  createAssetInfoForFolder("/vehicles")
end

local function migrateAssetsJob(job)
  local firstOldPath = ""
  stopMigration = false
  migrationProgress = 0
  migrationDone = false
  local recordCount = #assetRecords
  editor.logInfo("Started asset migration process...")

  for idx, record in ipairs(assetRecords) do
    if stopMigration then break end
    if not record.wasDeleted then
      firstOldPath = getFirstOldPath(record)
      if FS:fileExists(record.new) then
        migrationMessage = "Asset file already exists, skipping: " .. record.new
      elseif FS:copyFile(firstOldPath, record.new) then
        editor.logInfo("\tCopied '" .. firstOldPath .. "' to '" .. record.new .. "'")
        migrationMessage = "\tCopied '" .. firstOldPath .. "' to '" .. record.new .. "'"
        if type(record.old) == "table" then
          for _, old in ipairs(record.old) do
            FS:removeFile(old)
            editor.logInfo("\tRemoved '" .. old .. "'")
          end
        else
          FS:removeFile(record.old)
          editor.logInfo("\tRemoved '" .. record.old .. "'")
        end
      end
      --createAssetInfo(record.new)
    end
    migrationProgress = round(100 * idx / recordCount)
    coroutine.yield()
  end
  migrationMessage = "Done."
  print("Ended asset migration")
  migrationDone = true
end

local function onEditorGui()
  if editor.beginWindow(toolWindowName, "Asset Migration Tool") then
    imgui.SameLine()
    if imgui.Button("Reload List") then
      loadList()
    end

    -- imgui.SameLine()
    -- if imgui.Button("Fix Old Path References...") then
    -- end

    imgui.SameLine()
    if imgui.Button("Add More Files...") then
      editor_fileDialog.openFile(
        function(data)
          if not checkIfAlreadyMigrated(data.filepath) then
            listWasModified = true
            lastPath = data.path
            table.insert(assetRecords, { old = data.filepath, new = newPathNotSet, timestamp = os.time()})
          else
            editor.logError("File is already present in the asset migration records: '" .. data.filepath .. "'")
          end
        end,
        {{"Any files", "*"}},
        false,
        lastPath,
        true
      )
    end
    imgui.SameLine()
    -- TODO
    -- if imgui.Button("Check Mod DB") then
    --   checkModDbForPath("rock")
    -- end
    imgui.SameLine()
    if imgui.Button("Create Asset Info") then
      core_jobsystem.create(createAssetInfoForAllAssetsJob)
    end
    imgui.tooltip("Create .asset files for all game assets that dont have one yet")
    imgui.SameLine()
    if imgui.Button("Show Duplicates") then
      checkForDuplicateRecords()
      imgui.TextFilter_SetInputBuf(searchFilter, ":dupes")
      ffi.copy(searchFilter.InputBuf, ":dupes")
      forceFilterNow = true
    end
    imgui.SameLine()

    if imgui.Button("Refresh Hash Cache") then
      assetRegistry:loadAssetMigrationHashCache()
      assetRegistry:refreshAssetMigrationHashCache("/art")
      assetRegistry:refreshAssetMigrationHashCache("/levels")
    end

    imgui.PushStyleColor2(imgui.Col_Button, imgui.ImVec4(0.5,0,0,1))
    if imgui.Button("MIGRATE") then
      editor.openModalWindow(migrationDlg)
      core_jobsystem.create(migrateAssetsJob)
    end
    imgui.PopStyleColor()

    if listWasModified then
      imgui.SameLine()
      imgui.TextColored(imgui.ImVec4(1, 0, 0, 1), ">>")
      imgui.SameLine()
      if imgui.Button("Save Modified List") then
        if not saveList() then editor.openModalWindow(newPathNotSetMsgDlg) end
      end
      imgui.SameLine()
      imgui.TextColored(imgui.ImVec4(1, 0, 0, 1), "<<")
    end

    if not isGamePathSameAsUserPath() then
      imgui.TextWrapped("WARNING: your userpath is not the same as game path, it needs to be so the asset migration list is saved on SVN")
      imgui.TextWrapped("Currently, after Save, you would need to copy '" .. FS:getUserPath() .. "assets/asset_migration.json' to '" .. FS:getGamePath() .. "assets/asset_migration.json' and commit")
    end

    imgui.Separator()
    imgui.Text(tostring(tableSize(assetRecords)) .. " file record(s)")
    if imgui.ImGuiTextFilter_IsActive(searchFilter) then
      imgui.SameLine()
      imgui.Text("from which " .. tostring(visibleRecordCount) .. " found in filter")
    end

    if not tableIsEmpty(selectedIndices) then
      imgui.SameLine()

      if imgui.Button("Delete Selected") then
        editor.openModalWindow(deleteSelectionModalWndName)
      end
    end

    if editor.uiInputSearchTextFilter("Search...", searchFilter, imgui.GetContentRegionAvailWidth()) or forceFilterNow then
      filterList()
      forceFilterNow = false
    end

    local tableFlags = bit.bor(imgui.TableFlags_ScrollY,
      imgui.TableFlags_BordersV,
      imgui.TableFlags_BordersOuterH,
      imgui.TableFlags_Resizable,
      imgui.TableFlags_RowBg,
      imgui.TableFlags_NoBordersInBody)

    local colCount = 5

    if imgui.BeginTable('##assetRecordsTable', colCount, tableFlags) then
      local textBaseWidth = imgui.CalcTextSize('A').x
      imgui.TableSetupScrollFreeze(0, 1) -- Make top row always visible
      imgui.TableSetupColumn("#", imgui.TableColumnFlags_WidthFixed, 0)
      imgui.TableSetupColumn("Old Path(s)", imgui.TableColumnFlags_NoHide)
      imgui.TableSetupColumn("New Path", imgui.TableColumnFlags_NoHide)
      imgui.TableSetupColumn("Timestamp", imgui.TableColumnFlags_WidthFixed, textBaseWidth * 2)
      imgui.TableSetupColumn("Was Deleted", imgui.TableColumnFlags_WidthFixed, textBaseWidth * 2)
      imgui.TableHeadersRow()
      imgui.TableNextColumn()
      local oldPaths
      local delPath

      for idx, record in ipairs(assetRecords) do
        if record.visible == nil or record.visible then
          if type(record.old) == "table" then
            oldPaths = record.old
          else
            oldPaths = {record.old}
          end

          if not record.timestampStr and record.timestamp then
            record.timestampStr = os.date("%Y-%m-%d %H:%M:%S", record.timestamp)
          end

          imgui.TextColored(imgui.ImVec4(1, 1, 0, 1), tostring(idx))
          imgui.SameLine()

          selectRecordBoolPtr[0] = selectedIndices[idx] or false

          if imgui.Checkbox("##select" .. tostring(idx), selectRecordBoolPtr) then
            if selectRecordBoolPtr[0] then
              selectedIndices[idx] = true
            else
              selectedIndices[idx] = nil
            end
          end

          ffi.copy(inputTextNew, record.new)
          imgui.PushID1(tostring(idx))

          imgui.TableNextColumn()
          delPath = nil
          local noMoreOldPaths = #oldPaths == 1 and oldPaths[1] == ""
          for i, path in ipairs(oldPaths) do
            imgui.PushID1(tostring(i))
            ffi.copy(inputTextOld, path)
            imgui.PushStyleColor2(imgui.Col_Button, imgui.ImVec4(0.3, 0, 0, 0.5))
            if editor.uiIconImageButton(editor.icons.close, imgui.ImVec2(24, 24)) then
              delPath = path
            end
            imgui.PopStyleColor()
            if noMoreOldPaths then
              imgui.tooltip("Delete this entire record")
            else
              imgui.tooltip("Delete this path")
            end
            imgui.SameLine()
            imgui.PushItemWidth(-1)
            if imgui.InputText("", inputTextOld, 2048) then
              path = ffi.string(inputTextOld)
              if type(record.old) == "string" then record.old = path end
              listWasModified = true
            end
            imgui.PopItemWidth()
            imgui.PopID()
          end

          imgui.PushStyleColor2(imgui.Col_Button, imgui.ImVec4(0, 0.3, 0, 0.5))
          if editor.uiIconImageButton(editor.icons.add_circle, imgui.ImVec2(24, 24), nil, nil, nil) then
            recordIndex = idx
            editor_fileDialog.openFile(
                function(data)
                  listWasModified = true
                  if type(assetRecords[recordIndex].old) == "table" then
                    table.insert(assetRecords[recordIndex].old, data.filepath)
                  else
                    assetRecords[recordIndex].old = {assetRecords[recordIndex].old, data.filepath}
                  end
                  lastPath = data.path
                end,
                {{"Any files", "*"}},
                false,
                lastPath,
                true
              )
          end
          imgui.PopStyleColor()
          imgui.tooltip("Add another clone path to this migration redirect")
          imgui.SameLine()

          imgui.TableNextColumn()
          imgui.PushItemWidth(-1)
          if imgui.InputText("##newTxt", inputTextNew, 2048) then
            listWasModified = true
            record.new = ffi.string(inputTextNew)
          end
          imgui.PopItemWidth()

          imgui.TableNextColumn()
          if record.timestampStr then imgui.Text(record.timestampStr) end

          imgui.TableNextColumn()

          del[0] = record.wasDeleted or false

          if imgui.Checkbox("##selected" .. tostring(idx), del) then
            record.wasDeleted = del[0]
            listWasModified = true
          end

          imgui.TableNextColumn()
          imgui.PopID()

          if delPath then
            if noMoreOldPaths then
              table.remove(assetRecords, idx)
              break
            else
              for i, path in ipairs(oldPaths) do
                if path == delPath then
                  listWasModified = true
                  table.remove(oldPaths, i)
                  if tableIsEmpty(oldPaths) then record.old = "" end
                  if type(record.old) == "string" then record.old = "" end
                  break
                end
              end
            end
          end
        end
      end

      imgui.EndTable()
    end
  end

  editor.endWindow()

  if editor.beginModalWindow(deleteSelectionModalWndName, "Delete Selection") then
    imgui.Spacing()
    imgui.Text("Delete the selected asset migration records ? (cannot undo!)")
    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()
    imgui.Spacing()
    imgui.Spacing()

    if imgui.Button("Yes") then
      local n = #assetRecords

      for k = 1, n do
        if selectedIndices[k] == true then
          assetRecords[k] = nil
        end
      end

      local j = 0

      for k = 1, n do
        if assetRecords[k] then
          j = j + 1
          assetRecords[j] = assetRecords[k]
        end
      end

      for i = j + 1, n do
        assetRecords[i] = nil
      end

      selectedIndices = {}
      listWasModified = true

      editor.closeModalWindow(deleteSelectionModalWndName)
    end

    imgui.SameLine()
    if imgui.Button("Cancel") then
      editor.closeModalWindow(deleteSelectionModalWndName)
    end
  end
  editor.endModalWindow()

  if editor.beginModalWindow(newPathNotSetMsgDlg, "New Path Not Set") then
    imgui.Spacing()
    imgui.Text("Cannot save invalid records.\nYou have not set a new path for the old path:\n'" .. newPathNotSetForThisOldPath .. "'")
    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()
    if imgui.Button("OK") then
      editor.closeModalWindow(newPathNotSetMsgDlg)
    end
  end
  editor.endModalWindow()

  if editor.beginModalWindow(migrationDlg, "Asset Migration") then
    imgui.Spacing()
    imgui.Text("INFO: This will copy the first old file to the new path\nONLY if the new file doesnt exists, it will not overwrite it.")
    imgui.Text("Migrating " .. tostring(#assetRecords) .. " assets")
    imgui.Text("Progress: " .. migrationProgress .. "%%...")
    imgui.Text(migrationMessage)
    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()
    if not migrationDone then
      if imgui.Button("Abort") then
        editor.closeModalWindow(migrationDlg)
      end
    else
      if imgui.Button("Close") then
        editor.closeModalWindow(migrationDlg)
      end
    end
  end
  editor.endModalWindow()
end

local function onEditorActivated()
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  editor.registerWindow(toolWindowName, imgui.ImVec2(1200, 900))
  editor.registerModalWindow(deleteSelectionModalWndName, imgui.ImVec2(400, 100))
  editor.registerModalWindow(newPathNotSetMsgDlg, imgui.ImVec2(600, 200))
  editor.registerModalWindow(migrationDlg, imgui.ImVec2(600, 200))
  editor.addWindowMenuItem("Asset Migration Tool", onWindowMenuItem, {groupMenuName = 'Experimental'})
  loadList()
end

local function onExtensionLoaded()
end

M.onEditorInitialized = onEditorInitialized
M.onEditorActivated = onEditorActivated
M.onEditorGui = onEditorGui
M.onExtensionLoaded = onExtensionLoaded

return M

-- TODO:
-- add support to check the mod db grep for paths of used official assets in mods