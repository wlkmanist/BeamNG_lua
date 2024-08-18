-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local im = ui_imgui
local toolWindowName = "assetNamingScannerTool"
local toolName = "Asset Naming Scanner"
local defaultSearchPaths = {"/assets", "/art", "/core", "/levels", "/vehicles", "/gameplay", "/campaigns"}
local searchPaths = table.concat(defaultSearchPaths,", ")
local useDefaultSearchPaths = false
local assetNamingEntries = {}
local selectAll = im.BoolPtr(true)

local function sortByAssetName(a,b)
  return a.assetName > b.assetName
end

local function sortBySuggestedName(a,b)
  return a.suggestedName > b.suggestedName
end

local function sortByPath(a,b)
  return a.assetPath > b.assetPath
end

local function getSortingFunction(columnId)
  if columnId == 1 then
    return sortByAssetName
  elseif columnId == 2 then
    return sortBySuggestedName
  elseif columnId == 3 then
    return sortByPath
  end
  return sortByAssetName
end

local function openReferencePopup()
end

local function openRenamingRulesPopup()
end

local function assetNamesTable()
  local tableFlags = bit.bor(im.TableFlags_ScrollY,
  im.TableFlags_BordersV,
  im.TableFlags_BordersOuterH,
  im.TableFlags_Resizable,
  im.TableFlags_RowBg,
  im.TableFlags_NoBordersInBody,
  im.TableFlags_Sortable)

  local colCount = 6
  local columnNames = {"", "", "Old Name", "New Name", "Path", "Reference(s)"}
  local textBaseWidth = im.CalcTextSize('A').x
  if im.BeginTable('##assetNamesTable', colCount, tableFlags) then
    im.TableSetupScrollFreeze(0, 1) -- Make top row always visible
    im.TableSetupColumn("#", im.TableColumnFlags_NoSort + im.TableColumnFlags_WidthFixed, textBaseWidth * 2)
    im.TableSetupColumn("Selected", im.TableColumnFlags_NoSort + im.TableColumnFlags_WidthFixed, textBaseWidth * 2)
    im.TableSetupColumn("Old Name", im.TableColumnFlags_NoHide)
    im.TableSetupColumn("New Name", im.TableColumnFlags_NoHide)
    im.TableSetupColumn("Path", im.TableColumnFlags_NoHide)
    im.TableSetupColumn("Reference(s)", im.TableColumnFlags_NoSort)
    im.TableNextRow()
    for colIndex = 0, colCount-1, 1 do
      im.TableSetColumnIndex(colIndex)
      im.PushID1(tostring(colIndex))
      if colIndex == 0 then
        im.Text("#", false)
      elseif colIndex == 1 then
        if im.Checkbox("##select" .. tostring(colIndex), selectAll) then
        end
      else
        im.Text(columnNames[colIndex+1], false)
      end
      im.SameLine()
      im.TableHeader("")
      im.PopID(colIndex)
    end

    if im.TableGetSortSpecs().SpecsDirty then
      table.sort(assetNamingEntries, getSortingFunction(im.TableGetSortSpecs().Specs.ColumnIndex))
      if im.TableGetSortSpecs().Specs.SortDirection == 1 then
        arrayReverse(assetNamingEntries)
      end
      im.TableGetSortSpecs().SpecsDirty = false
    end
    im.TableNextRow()
    for index, entry in ipairs(assetNamingEntries) do
      for columnIndex = 0, colCount-1, 1 do
        im.TableNextColumn()
        if columnIndex == 0 then
          im.Text(tostring(index), false)
        elseif columnIndex == 1 then
          if im.Checkbox("##select" .. tostring(columnIndex), selectAll) then
          end
        elseif columnIndex == 5 then
          if entry.isReferenced then
            if im.Button("Used In...") then
              openReferencePopup()
            end
          else
              im.TextColored(im.ImVec4(1, 0, 0, 1), "Not available!")
          end
        else
          local fieldVal = ""
          local inputTextFlags = im.InputTextFlags_ReadOnly
          if columnIndex == 2 then
            fieldVal = entry.assetName
          elseif columnIndex == 3 then
            fieldVal = entry.suggestedName
            inputTextFlags = im.InputTextFlags_None
          elseif columnIndex == 4 then
            fieldVal = entry.assetPath
          end
          im.PushItemWidth(-1)
          if im.InputText("##AssetNamingField"..tostring(columnIndex)..fieldVal, editor.getTempCharPtr(fieldVal), nil, inputTextFlags) then
          end
        end
      end
    end
    im.EndTable()
  end
end

local function onEditorGui()
  if editor.beginWindow(toolWindowName, toolName) then
    im.Columns(2)
    im.SetColumnWidth(0, 150)
    im.TextUnformatted("Scan Path(s):")
    im.NextColumn()
    if im.Button("...") then
      editor_fileDialog.openFile(
        function(data)
          print(data.path)
          searchPaths = data.path
          useDefaultSearchPaths = false
        end, nil, true, "/")
    end
    im.SameLine()
    im.InputText("##SearchPaths", editor.getTempCharPtr(searchPaths), nil, im.InputTextFlags_ReadOnly)
    im.SameLine()
    if im.Button("Use Default Paths") then
      useDefaultSearchPaths = true
      searchPaths = table.concat(defaultSearchPaths,", ")
    end
    im.NextColumn()
    im.Columns(1)
    im.Separator()

    if im.Button("Start Scan") then
    end
    local cursorPos = im.GetContentRegionAvail()
    im.SameLine()

    local rulesButtonText = "Renaming Rules"
    im.SetCursorPosX(cursorPos.x - im.CalcTextSize(rulesButtonText).x)
    if im.Button(rulesButtonText) then
      openRenamingRulesPopup()
    end
    assetNamesTable()
  end
  editor.endWindow()
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  editor.addWindowMenuItem(toolName, onWindowMenuItem, {groupMenuName = 'Experimental'})
  editor.registerWindow(toolWindowName, im.ImVec2(420, 500))
end

M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized

return M