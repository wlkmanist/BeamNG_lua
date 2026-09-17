-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui

local M = {}

local popupName = "Open Rally Stage###rallyStageLoaderModal"
local stages = {}
local selectedMissionId = nil
local currentLevel = nil
local refreshStatus = nil
local popupOpen = false
local popupNeedsPosition = false

local function levelMatches(a, b)
  if not (a and b) then return false end
  return string.lower(tostring(a)) == string.lower(tostring(b))
end

local function missionLevel(mission)
  if mission.startTrigger and mission.startTrigger.level then
    return mission.startTrigger.level
  end
  return mission.id and mission.id:match("^([^/]+)") or nil
end

local function missionLabel(mission)
  local name = mission.name or mission.id or mission.missionFolder or "(unnamed)"
  if _tr then
    return _tr(name)
  end
  return tostring(name)
end

local function sortStages(a, b)
  local aLabel = string.lower(a.label or "")
  local bLabel = string.lower(b.label or "")
  if aLabel == bLabel then
    return tostring(a.id or "") < tostring(b.id or "")
  end
  return aLabel < bLabel
end

local function stageDisplayLabel(stage)
  local label = stage.label or "(unnamed)"
  if stage.devMission then
    label = "[DEV] " .. label
  end
  return label
end

local function refreshStages()
  table.clear(stages)
  selectedMissionId = nil
  refreshStatus = nil

  currentLevel = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  if not currentLevel or currentLevel == "" then
    refreshStatus = "No level is currently loaded."
    return
  end

  local missions = gameplay_missions_missions
  if not (missions and missions.getFilesData) then
    refreshStatus = "Mission data is not available."
    return
  end

  for _, mission in ipairs(missions.getFilesData() or {}) do
    if mission.missionType == "rallyStage" and mission.missionFolder and levelMatches(missionLevel(mission), currentLevel) then
      table.insert(stages, {
        id = mission.id,
        label = missionLabel(mission),
        devMission = mission.devMission == true,
        missionFolder = mission.missionFolder,
      })
    end
  end

  table.sort(stages, sortStages)
  if #stages == 0 then
    refreshStatus = "No Rally Stage missions found in the current level."
  end
end

local function selectedStage()
  if not selectedMissionId then return nil end
  for _, stage in ipairs(stages) do
    if stage.id == selectedMissionId then return stage end
  end
  return nil
end

local function close(openPtr)
  if openPtr then openPtr[0] = false end
  popupOpen = false
  im.CloseCurrentPopup()
end

local function openStage(rallyEditor, openPtr)
  local stage = selectedStage()
  if not (stage and stage.missionFolder) then return end

  rallyEditor.loadForMissionEditor(stage.missionFolder)
  rallyEditor.showRallyTool()
  close(openPtr)
end

local function drawStageList()
  im.BeginChild1("##rallyStageLoaderList", im.ImVec2(0, 320 * im.uiscale[0]), im.WindowFlags_ChildWindow)
  for _, stage in ipairs(stages) do
    local selected = stage.id == selectedMissionId
    local label = stageDisplayLabel(stage) .. "###" .. tostring(stage.id)
    if stage.devMission then
      im.PushStyleColor2(im.Col_Text, im.ImVec4(1.0, 0.72, 0.25, 1.0))
    end
    if im.Selectable1(label, selected) then
      selectedMissionId = stage.id
    end
    if stage.devMission then
      im.PopStyleColor(1)
    end
  end
  im.EndChild()
end

local function drawSelectedStageDetails()
  local stage = selectedStage()
  if not stage then return end

  if stage.devMission then
    im.TextColored(im.ImVec4(1.0, 0.72, 0.25, 1.0), "DEV mission only")
  end
  im.Text("Mission: " .. tostring(stage.id or ""))
  im.Text("Folder: " .. tostring(stage.missionFolder or ""))
end

function M.draw(rallyEditor, openPtr)
  if not (openPtr and rallyEditor) then return end

  if openPtr[0] and not popupOpen then
    refreshStages()
    im.OpenPopup(popupName)
    popupOpen = true
    popupNeedsPosition = true
  end

  if popupNeedsPosition then
    local viewport = im.GetMainViewport()
    local topMargin = 64 * im.uiscale[0]
    local pos = im.ImVec2(
      viewport.Pos.x + viewport.Size.x * 0.5,
      viewport.Pos.y + topMargin
    )
    im.SetNextWindowPos(pos, im.Cond_Always, im.ImVec2(0.5, 0))
  end

  if im.BeginPopupModal(popupName, nil, im.WindowFlags_AlwaysAutoResize) then
    popupNeedsPosition = false
    im.HeaderText("Open Rally Stage")
    im.Text("Current level: " .. tostring(currentLevel or "(none)"))
    im.SameLine()
    if im.Button("Refresh") then
      refreshStages()
    end

    im.Separator()
    if refreshStatus then
      im.TextWrapped(refreshStatus)
    else
      im.TextWrapped("Select an existing Rally Stage mission to load its notebook in the Rally Editor.")
      drawStageList()
      drawSelectedStageDetails()
    end

    im.Separator()
    local disabled = selectedStage() == nil
    if disabled then im.BeginDisabled() end
    if im.Button("Open", im.ImVec2(120, 0)) then
      openStage(rallyEditor, openPtr)
    end
    if disabled then im.EndDisabled() end
    im.SameLine()
    if im.Button("Cancel", im.ImVec2(120, 0)) then
      close(openPtr)
    end
    im.EndPopup()
  elseif popupOpen and not openPtr[0] then
    popupOpen = false
    popupNeedsPosition = false
  end
end

return M
