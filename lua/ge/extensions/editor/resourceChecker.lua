-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = 'editor_resourceChecker'
local im = ui_imgui
local resourceUtil = extensions.editor_resourceChecker_resourceUtil

local pos = im.ImVec2(0, 0)
local sizeMin = im.ImVec2(0, 0)
local sizeMax = im.ImVec2(-1, -1)

local toolWindowName = 'resourceChecker'

local buttonPress = 0
local buttonPressleft = 3

local verifier
local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function getProgress()
  local progress = resourceUtil.getProgress()
  return progress
end

local function getPlayerVehicle()
  local vehid = be:getPlayerVehicleID(0)
  local vehiclepath
  -- idiot proof
  if string.match(vehid, "-1") then
  else
    -- vehicle exist
    local getveh = scenetree.findObjectById(vehid)
    local playerveh = getveh.JBeam
    --print(playervehicle)
    vehiclepath = ("/vehicles/" .. playerveh .. "/")
    return vehiclepath
  end
end

local isDoubleClicked = {}
local isSelected = {}
local function popUp(name)
  local win = im.GetMainViewport()
  local stop = nil
  pos.x = win.Pos.x + win.Size.x / 2
  pos.y = win.Pos.y + win.Size.y / 2

  im.SetNextWindowPos(pos, im.ImGuiCond_Always, im.ImVec2(0.5, 0))

  if im.BeginPopupModal(name, nil, im.WindowFlags_AlwaysAutoResize+im.WindowFlags_NoResize+im.WindowFlags_NoMove+im.WindowFlags_NoCollapse+im.WindowFlags_NoDocking+im.WindowFlags_NoTitleBar) then
    isDoubleClicked = {}
    local cancel
    if cancel == 1 then
      im.Text("Cancelling job")
    else
      im.Text("Checking files")
    end
    if getProgress() then
      im.ProgressBar(getProgress()/100, im.ImVec2(300* im.uiscale[0], 0))
      im.SameLine()
      if im.Button("Cancel") then
        resourceUtil.stopProgress()
        cancel = 1
      end
    end
    if getProgress() == 100 or getProgress() == nil then
      im.CloseCurrentPopup()
    end
    im.EndPopup()
  end
end

local btnpress = 3
local resExplorer
local function warning(name, level, count, unusType, selected)
  local win = im.GetMainViewport()
  local stop = nil
  pos.x = win.Pos.x + win.Size.x / 2
  pos.y = win.Pos.y + win.Size.y / 2

  im.SetNextWindowPos(pos, im.ImGuiCond_Always, im.ImVec2(0.5, 0))

  if im.BeginPopupModal(name, nil, im.WindowFlags_AlwaysAutoResize+im.WindowFlags_NoResize+im.WindowFlags_NoMove+im.WindowFlags_NoCollapse+im.WindowFlags_NoDocking) then
    im.Text("This action will remove all files that were listed ("..count..").\nThis cannot be undone.\nMake sure to backup your work.\nThis feature only works for unpacked content.")
    popUp("Progress")
    if im.Button("Ok ("..btnpress..")") then
      if btnpress > 1 then
        btnpress = btnpress - 1
      else
        btnpress = 3
        im.OpenPopup("Progress")
        resExplorer = resourceUtil.removeUnused(level, unusType, selected)
        im.CloseCurrentPopup()
      end
    end
    im.SameLine()
    if im.Button("Cancel") then
      im.CloseCurrentPopup()
    end
    im.EndPopup()
  end
end

local searchTxt = im.ArrayChar(256, "")
local searchFilter = false
local skipK = {}

local function drawRectBg(text, color, hover, smol)
  local textSize = im.CalcTextSize(text)
  local leftT = im.GetCursorScreenPos()
  leftT = im.ImVec2(leftT.x - 2, leftT.y - 1)
  if hover == 1 then
    leftT = im.ImVec2(leftT.x - 2, (leftT.y - 1)-textSize.y-1)
  end
  local window = im.GetWindowWidth()
  local rightB
  if smol == 1 then
    rightB = im.ImVec2(leftT.x+textSize.x+3, leftT.y+textSize.y+4)
  else
    rightB = im.ImVec2(leftT.x + window, leftT.y + textSize.y+1)
  end
  im.ImDrawList_AddRectFilled(im.GetWindowDrawList(), leftT, rightB, im.GetColorU322(color), 0, nil)
end

local function resultUI(text, data, isText, unusType, level, itms)
  isSelected = {}
  local windowSize = im.GetContentRegionAvail()
  im.Text(text)
  local textSize = im.CalcTextSize(text)
  im.Separator()
  if editor.uiInputSearch(nil, searchTxt, 400* im.uiscale[0]) then
    if ffi.string(searchTxt) ~= nil then
      searchFilter = true
    end
  end
  im.Separator()
  im.BeginChild1("Child1", im.ImVec2(0, windowSize.y-textSize.y-(im.GetFontSize()*3.5)-5), false, im.WindowFlags_ChildWindow+im.WindowFlags_HorizontalScrollbar)
  local fontPushed = im.PushFont3("robotomono_regular")
  im.Spacing()
  if isText == 1 then
    local count = 0
    local f = io.open("temp/resourceChecker.json", "r")
    for line in f:lines() do
      line = line:gsub('{', '')
      line = line:gsub('}', '')
      line = line:gsub(',', '')
      line = line:gsub('"', ' ')
      line = line:gsub('Format:', '   Format:')
      line = line:gsub('Reason:', '    Reason:')
      if line ~= nil and line ~= "" then
        if searchFilter == true and not string.match(string.lower(line), string.lower(ffi.string(searchTxt))) then
          goto skipLinetxt
        end
        count = count + 1
        if (count % 2 == 0) then
          if isDoubleClicked[tostring(line)] == true then
            drawRectBg(tostring(line), im.ImVec4(0.8, 0.4, 0.1, 1))
            im.TextColored(im.ImVec4(1, 1, 1, 1), tostring(line))
          else
            drawRectBg(tostring(line), im.ImVec4(1, 1, 1, 0.1))
            im.TextColored(im.ImVec4(0.5, 0.9, 1, 1), tostring(line))
          end
          if im.IsItemHovered() and im.IsMouseClicked(0) then
            if isDoubleClicked[tostring(line)] == true then
              isDoubleClicked[tostring(line)] = false
            else
            isDoubleClicked[tostring(line)] = true
            end
          elseif im.IsItemHovered() then
            drawRectBg(tostring(line), im.ImVec4(0.7, 0.7, 0.7, 0.2), 1)
          end
        else
          if isDoubleClicked[tostring(line)] == true then
            drawRectBg(tostring(line), im.ImVec4(0.8, 0.4, 0.1, 1))
            im.TextColored(im.ImVec4(1, 1, 1, 1), tostring(line))
          else
            drawRectBg(tostring(line), im.ImVec4(0, 0, 0, 0.1))
            im.TextColored(im.ImVec4(0.5, 0.9, 1, 1), tostring(line))
          end
          if im.IsItemHovered() and im.IsMouseClicked(0) then
            if isDoubleClicked[tostring(line)] == true then
              isDoubleClicked[tostring(line)] = false
            else
            isDoubleClicked[tostring(line)] = true
            end
          elseif im.IsItemHovered() then
            drawRectBg(tostring(line), im.ImVec4(0.7, 0.7, 0.7, 0.2), 1)
          end
        end
        ::skipLinetxt::
      end
    end
    f:close()
  else
    im.Columns(2)
    im.SetColumnWidth(0, 60)
    im.TextColored(im.ImVec4(0.5, 0.9, 1, 1), "No.")
    im.NextColumn()
    --im.PushItemWidth(200)
    im.Spacing()
    im.TextColored(im.ImVec4(0.5, 0.9, 1, 1), "Issue")
    im.Spacing()
    im.Separator()
    im.Separator()
    im.Spacing()
    im.NextColumn()
    local count = 0
    for k,v in pairs(data) do
      if (type(v) ~= "table") then
        if searchFilter == true and skipK[k] then
          goto skipEntr
        end
        count = count + 1
        if (count % 2 == 0) then
          if isDoubleClicked[k] == true then
            drawRectBg(tostring(k), im.ImVec4(0.8, 0.4, 0.1, 1))
            im.TextColored(im.ImVec4(1, 1, 1, 1), tostring(k))
          else
            drawRectBg(tostring(k), im.ImVec4(1, 1, 1, 0.1))
            im.TextColored(im.ImVec4(0.5, 0.9, 1, 1), tostring(k))
          end
        else
          if isDoubleClicked[k] == true then
            drawRectBg(tostring(k), im.ImVec4(0.8, 0.4, 0.1, 1))
            im.TextColored(im.ImVec4(1, 1, 1, 1), tostring(k))
          else
            drawRectBg(tostring(k), im.ImVec4(0, 0, 0, 0.1))
            im.TextColored(im.ImVec4(0.5, 0.9, 1, 1), tostring(k))
          end
        end
      elseif (type(v) == "table") then
        im.TextColored(im.ImVec4(0.5, 0.9, 1, 1), tostring(k))
        local count = 0
        for k,v in pairs(v) do
          if searchFilter == true and skipK[k] then
            goto skipEntr2
          end
          count = count + 1
          if (count % 2 == 0) then
            drawRectBg(tostring(count), im.ImVec4(1, 1, 1, 0.1))
            im.TextColored(im.ImVec4(0.5, 0.9, 1, 1), tostring(count))
          else
            drawRectBg(tostring(count), im.ImVec4(0, 0, 0, 0.1))
            im.TextColored(im.ImVec4(0.5, 0.9, 1, 1), tostring(count))
          end
          ::skipEntr2::
        end
      end
      ::skipEntr::
    end
    skipK = {}
    im.NextColumn()
    local count = 0
    for k,v in pairs(data) do
      if (type(v) ~= "table") then
        if searchFilter == true and not string.match(string.lower(v), string.lower(ffi.string(searchTxt))) then
          skipK[k] = true
          goto skipLine2
        end
        count = count + 1
        if (count % 2 == 0) then
          if isDoubleClicked[k] == true then
            isSelected[v] = true
            drawRectBg(tostring(v), im.ImVec4(0.8, 0.4, 0.1, 1))
            im.TextColored(im.ImVec4(1, 1, 1, 1), tostring(v))
          else
            drawRectBg(tostring(v), im.ImVec4(1, 1, 1, 0.1))
            im.TextColored(im.ImVec4(0.5, 0.9, 1, 1), tostring(v))
          end
        else
          if isDoubleClicked[k] == true then
            isSelected[v] = true
            drawRectBg(tostring(v), im.ImVec4(0.8, 0.4, 0.1, 1))
            im.TextColored(im.ImVec4(1, 1, 1, 1), tostring(v))
          else
            drawRectBg(tostring(v), im.ImVec4(0, 0, 0, 0.1))
            im.TextColored(im.ImVec4(0.5, 0.9, 1, 1), tostring(v))
          end
        end
        if im.IsItemHovered() and im.IsMouseClicked(1) then
          local path = tostring(v):match(".*. (.+)")
          if path then
            Engine.Platform.exploreFolder(path)
          else
            Engine.Platform.exploreFolder(tostring(v))
          end
        end
        if im.IsItemHovered() and im.IsMouseClicked(0) then
          if isDoubleClicked[k] == true then
            isDoubleClicked[k] = false
          else
          isDoubleClicked[k] = true
          end
        elseif im.IsItemHovered() then
          drawRectBg(tostring(v), im.ImVec4(0.7, 0.7, 0.7, 0.2), 1)
        end
      elseif (type(v) == "table") then
        im.TextColored(im.ImVec4(0.5, 0.9, 1, 1), tostring(k))
        local count = 0
        for k,v in pairs(v) do
          if searchFilter == true then
            if not string.match(string.lower(v[1]), string.lower(ffi.string(searchTxt))) and not string.match(string.lower(v[4]), string.lower(ffi.string(searchTxt))) and not string.match(string.lower(v[3]), string.lower(ffi.string(searchTxt))) then
              skipK[k] = true
              goto skipLine3
            end
          end
          count = count + 1
          if (count % 2 == 0) then
            if isDoubleClicked[k] == true then
              drawRectBg(tostring(v), im.ImVec4(0.8, 0.4, 0.1, 1))
              im.TextColored(im.ImVec4(1, 1, 1, 1), v[1].." with "..v[4].." in "..v[3])
            else
              drawRectBg(tostring(v), im.ImVec4(1, 1, 1, 0.1))
              im.TextColored(im.ImVec4(0.5, 0.9, 1, 1), v[1].." with "..v[4].." in "..v[3])
            end
          else
            if isDoubleClicked[k] == true then
              drawRectBg(tostring(v), im.ImVec4(0.8, 0.4, 0.1, 1))
              im.TextColored(im.ImVec4(1, 1, 1, 1), v[1].." with "..v[4].." in "..v[3])
            else
              drawRectBg(tostring(v), im.ImVec4(0, 0, 0, 0.1))
              im.TextColored(im.ImVec4(0.5, 0.9, 1, 1), v[1].." with "..v[4].." in "..v[3])
            end
          end
          if im.IsItemHovered() and im.IsMouseClicked(1) then
              Engine.Platform.exploreFolder(tostring(v[3]))
          end
          if im.IsItemHovered() and im.IsMouseClicked(0) then
            if isDoubleClicked[k] == true then
              isDoubleClicked[k] = false
            else
            isDoubleClicked[k] = true
            end
          elseif im.IsItemHovered() then
            drawRectBg(tostring(v), im.ImVec4(0.7, 0.7, 0.7, 0.2), 1)
          end
          ::skipLine3::
        end
      end
      ::skipLine2::
    end
  end
  if fontPushed then
    im.PopFont()
    --im.SetWindowFontScale(1)
  end
  im.EndChild()
  im.Separator()
  im.Spacing()
  im.Dummy(im.ImVec2(5* im.uiscale[0], 0))
  im.SameLine()
  drawRectBg("LMB", im.ImVec4(0, 0, 0, 0.3), 0, 1)
  im.Text("LMB")
  im.SameLine()
  im.Text(" Select row")
  im.SameLine()
  im.Dummy(im.ImVec2(50* im.uiscale[0], 0))
  im.SameLine()
  drawRectBg("RMB", im.ImVec4(0, 0, 0, 0.3), 0, 1)
  im.Text("RMB")
  im.SameLine()
  im.Text(" Open in Explorer")
  if unusType ~= nil and level ~= nil then
    warning("Remove all unused files", level, itms, unusType)
    im.SameLine()
    local buttonWidth = 160* im.uiscale[0]
    local cnt = 0
    if not tableIsEmpty(isSelected) then
      for k,v in pairs(isSelected) do
        cnt = cnt + 1
      end
      warning("Remove only selected files", level, cnt, unusType, isSelected)
      im.Dummy(im.ImVec2(im.GetContentRegionAvailWidth()-buttonWidth*2-11* im.uiscale[0], 0))
    else
      im.Dummy(im.ImVec2(im.GetContentRegionAvailWidth()-buttonWidth-5* im.uiscale[0], 0))
    end
    im.SameLine()
    local removeButtonCol = im.ImVec4(1, 0, 0, 0.7)
    im.PushStyleColor2(im.Col_Button, removeButtonCol)
    if not tableIsEmpty(isSelected) then
      if im.Button("Remove selected files ("..cnt..")", im.ImVec2(buttonWidth,0)) then
      im.OpenPopup("Remove only selected files")
      end
      if im.IsItemHovered() then
        im.BeginTooltip()
        im.Text("Permanently removes selected files from unpacked level")
        im.EndTooltip()
      end
    end
    im.SameLine()
    if im.Button("Remove all unused files", im.ImVec2(buttonWidth,0)) then
      im.OpenPopup("Remove all unused files")
    end
    im.PopStyleColor()
    if im.IsItemHovered() then
      im.BeginTooltip()
      im.Text("Permanently removes unused files from unpacked level")
      im.EndTooltip()
    end
  end
end

local btnText = "error"
local useVeh = false

local function matTab()
  local convertdata
  local getlevel = getCurrentLevelIdentifier()
  if not getlevel then
    im.TextColored(im.ImVec4(1, 1, 0.2, 1), "Level is not loaded")
  else
    if getPlayerVehicle() then
      if useVeh == true then btnText = "Check current level" else btnText = "Check current vehicle" end
      if im.Button(btnText, im.ImVec2(220* im.uiscale[0],0)) then
        if useVeh == false then useVeh = true else useVeh = false end
      end
    else
      useVeh = false
    end
    local matdata = "/levels/"..getlevel.."/"
    if useVeh == true then matdata = getPlayerVehicle() end
    im.Text("Checking: "..matdata)
    popUp("Progress")
    im.Text("This tool is verifying types of materials and issues")
    if im.Button("Check materials version", im.ImVec2(152* im.uiscale[0],0)) then
      im.OpenPopup("Progress")
      convertdata = matdata
      verifier = resourceUtil.verifyVersion(convertdata)
    end
    if im.IsItemHovered() then
      im.BeginTooltip()
      im.Text("Checks for a materials version in the level")
      im.EndTooltip()
    end
    im.SameLine()
    if im.Button("Verify duplicates", im.ImVec2(120* im.uiscale[0],0)) then
      im.OpenPopup("Progress")
      convertdata = matdata
      verifier = resourceUtil.verifyDuplicate(convertdata)
    end
    if im.IsItemHovered() then
      im.BeginTooltip()
      im.Text("Looks for a material duplicates in the level")
      im.EndTooltip()
    end
    im.SameLine()
    if im.Button("Fix persistentId", im.ImVec2(121* im.uiscale[0],0)) then
      im.OpenPopup("Progress")
      convertdata = matdata
      verifier = resourceUtil.fixPID(convertdata)
    end
    if im.IsItemHovered() then
      im.BeginTooltip()
      im.Text("Fixes missing or duplicated persistendID in materials")
      im.EndTooltip()
    end
    if im.Button("Check texture map", im.ImVec2(131* im.uiscale[0],0)) then
      im.OpenPopup("Progress")
      convertdata = matdata
      verifier = resourceUtil.checkMatTex(convertdata)
    end
    if im.IsItemHovered() then
      im.BeginTooltip()
      im.Text("Validates textures mapping in materials")
      im.EndTooltip()
    end
    im.SameLine()
    if im.Button("Check texture files", im.ImVec2(131* im.uiscale[0],0)) then
      im.OpenPopup("Progress")
      convertdata = matdata
      verifier = resourceUtil.checkTex(convertdata)
    end
    if im.IsItemHovered() then
      im.BeginTooltip()
      im.Text("Checks for a textures issues in materials")
      im.EndTooltip()
    end
    im.SameLine()
    if im.Button("Check missing mats", im.ImVec2(131* im.uiscale[0],0)) then
      im.OpenPopup("Progress")
      convertdata = matdata
      verifier = resourceUtil.checkmissingMats(convertdata)
    end
    if im.IsItemHovered() then
      im.BeginTooltip()
      im.Text("Checks for a missing materials mapping in currently loaded models")
      im.EndTooltip()
    end
    im.Spacing()
    im.Separator()
    im.Spacing()
    if not verifier and getProgress() == nil then
      im.Text("Run verifier to get informations!")
    elseif not verifier and getProgress() ~= nil then
      im.Text("Working...")
    elseif verifier and verifier[1] == 2 and verifier[5] == 1 then
      im.TextColored(im.ImVec4(1, 1, 0.2, 1), "Verifying done")
      im.Spacing()
      resultUI("Detected ("..verifier[2]..") V0 materials in : ", verifier[3])
    elseif verifier and verifier[1] == 3 and verifier[5] == 1 then
      im.TextColored(im.ImVec4(1, 1, 0.2, 1), "Verifying done")
      resultUI("Detected duplicated materials ("..verifier[2].."),\nit's required to avoid doing that as it can lead into issues.", verifier[4])
    elseif verifier and verifier[1] == 5 and verifier[5] == 1 then
      im.TextColored(im.ImVec4(1, 1, 0.2, 1), "Finished fixing persistentIds")
      resultUI("Fixed ("..verifier[2]..") invalid persistentIds in files: ", verifier[4])
    elseif verifier and verifier[1] == 6 and verifier[5] == 1 then
      im.TextColored(im.ImVec4(1, 1, 0.2, 1), "Finished checking texture maps\nFound: "..verifier[2]+verifier[3]+verifier[6].." issues")
      resultUI("There is ("..verifier[2]..") issues with wrong path to files.\nDetected ("..verifier[3]..") missing textures in materials.\nFound ("..verifier[6]..") issues with Texture Cooker files.\nPlease use .png file extension in Texture Cooker materials to make sure everything works correctly.\n*Numbers next to map name correspond to material layer.", verifier[4], 1)
    elseif verifier and verifier[1] == 7 and verifier[5] == 1 then
      im.TextColored(im.ImVec4(1, 1, 0.2, 1), "Finished checking texture files\nFound: "..verifier[2]+verifier[3]+verifier[6].." issues")
      resultUI("There is ("..verifier[2]..") issues with incorrect file format.\nDetected ("..verifier[3]..") textures that are not power of 2.\nFound ("..verifier[6]..") textures that cannot be cooked.\n*Numbers next to map name correspond to material layer.", verifier[4], 1)
    elseif verifier and verifier[1] == 8 and verifier[5] == 1 then
      im.TextColored(im.ImVec4(1, 1, 0.2, 1), "Verifying done")
      resultUI("Detected ("..verifier[2]..") missing materials: ", verifier[4])
    elseif verifier and verifier[5] == 2 then
      im.TextColored(im.ImVec4(1, 0, 0, 1), "Verification failed")
    end
  end
end

local function resTab()
  local getlevel = getCurrentLevelIdentifier()
  if not getlevel then
    im.TextColored(im.ImVec4(1, 1, 0.2, 1), "Level is not loaded")
  else
    im.Text("Checking: ".."/levels/"..getlevel.."/")
    popUp("Progress")
    im.Text("Generate informations about assets loaded in game")
    local buttonSize = 140* im.uiscale[0]
    if im.Button("Loaded TSStatics", im.ImVec2(buttonSize,0)) then
      im.OpenPopup("Progress")
      resExplorer = resourceUtil.checkStatic()
    end
    if im.IsItemHovered() then
      im.BeginTooltip()
      im.Text("Generates a list of currently loaded TSStatics")
      im.EndTooltip()
    end
    im.SameLine()
    if im.Button("Available ForestItems", im.ImVec2(buttonSize,0)) then
      im.OpenPopup("Progress")
      resExplorer = resourceUtil.checkForest()
    end
    if im.IsItemHovered() then
      im.BeginTooltip()
      im.Text("Generates a list of available Forest Meshes")
      im.EndTooltip()
    end
    im.SameLine()
    if im.Button("Loaded Terrains", im.ImVec2(buttonSize,0)) then
      im.OpenPopup("Progress")
      resExplorer = resourceUtil.checkTerrains()
    end
    if im.IsItemHovered() then
      im.BeginTooltip()
      im.Text("Generates a list of used terrains")
      im.EndTooltip()
    end
    if im.Button("Unused Materials", im.ImVec2(buttonSize,0)) then
      im.OpenPopup("Progress")
      resExplorer = resourceUtil.checkUnusedMats(getlevel)
    end
    if im.IsItemHovered() then
      im.BeginTooltip()
      im.Text("Generates a list of unused materials")
      im.EndTooltip()
    end
    im.SameLine()
    if im.Button("Unused Meshes", im.ImVec2(buttonSize,0)) then
      im.OpenPopup("Progress")
      resExplorer = resourceUtil.checkUnusedModels(getlevel)
    end
    if im.IsItemHovered() then
      im.BeginTooltip()
      im.Text("Generates a list of unused meshes")
      im.EndTooltip()
    end
    im.SameLine()
    if im.Button("Unused Textures", im.ImVec2(buttonSize,0)) then
      im.OpenPopup("Progress")
      resExplorer = resourceUtil.unusedTextures(getlevel)
    end
    if im.IsItemHovered() then
      im.BeginTooltip()
      im.Text("Generates a list of unused textures")
      im.EndTooltip()
    end
    im.Spacing()
    im.Separator()
    im.Spacing()
    if not resExplorer and getProgress() == nil then
      im.Text("Press one of the buttons to get informations!")
    elseif not resExplorer and getProgress() ~= nil then
      im.Text("Working...")
    elseif resExplorer and resExplorer[1] == 1 and resExplorer[5] == 1 then
      im.TextColored(im.ImVec4(1, 1, 0.2, 1), "Task complete")
      resultUI("There is currectly ("..resExplorer[2]..") TSStatics loaded in scene with ("..resExplorer[3].. ") instances that have a total size of "..resExplorer[6].." MB: ", resExplorer[4])
    elseif resExplorer and resExplorer[1] == 2 and resExplorer[5] == 1 then
      im.TextColored(im.ImVec4(1, 1, 0.2, 1), "Task complete")
      resultUI("There is currectly ("..resExplorer[2]..") ForestItems available in the level that have a total size of "..resExplorer[6].." MB: ", resExplorer[4])
    elseif resExplorer and resExplorer[1] == 3 and resExplorer[5] == 1 then
      im.TextColored(im.ImVec4(1, 1, 0.2, 1), "Task complete")
      resultUI("There is currectly ("..resExplorer[2]..") TerrainBlocks loaded in scene that have a total size of "..resExplorer[3].." MB: ", resExplorer[4])
    elseif resExplorer and resExplorer[1] == 4 and resExplorer[5] == 1 then
      im.TextColored(im.ImVec4(1, 1, 0.2, 1), "Task complete")
      resultUI("There is currectly ("..resExplorer[2]..") unused Materials in the level: ", resExplorer[4], 0, 1, getlevel, resExplorer[2])
    elseif resExplorer and resExplorer[1] == 5 and resExplorer[5] == 1 then
      im.TextColored(im.ImVec4(1, 1, 0.2, 1), "Task complete")
      resultUI("There is currectly ("..resExplorer[2]..") unused Meshes in the level that have a total size of "..resExplorer[3].." MB: ", resExplorer[4], 0, 2, getlevel, resExplorer[2])
    elseif resExplorer and resExplorer[1] == 6 and resExplorer[5] == 1 then
      im.TextColored(im.ImVec4(1, 1, 0.2, 1), "Task complete")
      resultUI("There is currectly ("..resExplorer[2]..") unused textures in the level that have a total size of "..resExplorer[3].." MB: ", resExplorer[4], 0, 3, getlevel, resExplorer[2])
    elseif resExplorer and resExplorer[1] == 7 and resExplorer[5] == 1 then
      im.TextColored(im.ImVec4(1, 1, 0.2, 1), "Task complete, removed: ("..resExplorer[2]..") files with total size of "..resExplorer[3].." MB")
    elseif resExplorer and resExplorer[5] == 2 then
      im.TextColored(im.ImVec4(1, 0, 0, 1), "Task failed")
    end
  end
end

local function onEditorGui()
  if editor.beginWindow(toolWindowName, "Resources Checker") then
    im.Text("Check resources of current level")
    im.Spacing()

    if im.BeginTabBar("tabs") then
      if im.BeginTabItem("Materials Verification", nil, im.TabItemFlags_None) then
        matTab()
        im.EndTabItem()
      end
      if im.BeginTabItem("Resources Explorer", nil, im.TabItemFlags_None) then
        resTab()
        im.EndTabItem()
      end
    end
    --im.Spacing()
  end
  editor.endWindow()
end

local function jobData(type, data)
  if type == 2 then
    verifier = data
  end
  if type == 3 then
    resExplorer = data
  end
end


local function onEditorActivated()

end

local function onEditorDeactivated()

end

local function onEditorInitialized()
  editor.addWindowMenuItem("Resources Checker", onWindowMenuItem)
  editor.registerWindow(toolWindowName, im.ImVec2(500, 300))
end

M.jobData = jobData
M.onEditorGui = onEditorGui
M.onWindowMenuItem = onWindowMenuItem
M.onEditorInitialized = onEditorInitialized
M.onEditorActivated = onEditorActivated
M.onEditorDeactivated = onEditorDeactivated

return M