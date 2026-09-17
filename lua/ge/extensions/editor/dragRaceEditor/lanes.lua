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

local allLanes = {}
local selectedLaneIndex = -1

M.loadAllLanes = function()
  allLanes = dragSaveSystem.getAllLanes()
  log('D', 'drag_race_editor', 'Loaded ' .. #allLanes .. ' lanes')
end

M.getAllLanes = function()
  return allLanes
end

M.getSelectedLaneIndex = function()
  return selectedLaneIndex
end

M.setSelectedLaneIndex = function(index)
  selectedLaneIndex = index
end

M.getSelectedLane = function()
  if selectedLaneIndex > 0 and selectedLaneIndex <= #allLanes then
    return allLanes[selectedLaneIndex]
  end
  return nil
end

M.selectLane = function(index)
  selectedLaneIndex = index
  local lane = M.getSelectedLane()
  if lane then
    log('D', 'drag_race_editor', 'Selected lane: ' .. lane.name)
  end
end

M.addLane = function()
  local lane = {
    id = "new_lane_" .. (#allLanes + 1),
    name = "New Lane",
    shortName = "Lane " .. (#allLanes + 1),
    longName = "Lane " .. (#allLanes + 1),
    color = "blue",
    laneOrder = #allLanes + 1,
    waypointIds = {},
    boundaryId = "",
    metadata = {
      created = os.date(),
      modified = os.date()
    }
  }

  table.insert(allLanes, lane)
  M.selectLane(#allLanes)
  utils.markUnsavedChanges()
end

M.removeSelectedLane = function()
  if selectedLaneIndex > 0 and selectedLaneIndex <= #allLanes then
    table.remove(allLanes, selectedLaneIndex)
    selectedLaneIndex = selectedLaneIndex - 1
    if selectedLaneIndex == 0 and #allLanes > 0 then
      selectedLaneIndex = 1
    end
    if #allLanes <= 0 then
      selectedLaneIndex = -1
    end
    utils.markUnsavedChanges()
  end
end

M.saveLane = function(lane)
  if not lane then return false end

  local levelPath = dragSaveSystem.getCurrentLevelDragPath()
  if not levelPath then
    utils.logError("No level loaded, cannot save lane")
    return false
  end

  local filePath = levelPath .. lane.id .. ".lane.json"
  return dragSaveSystem.saveLane(lane, filePath)
end

M.drawLanesSection = function()
  im.BeginChild1("lanes", im.ImVec2(0, 150), true)
  im.Spacing()
  if not utils.dragSectionHeader("Lanes", "##lanesListChild", true) then
    im.EndChild()
    return
  end

  if im.Button("Add Lane") then
    M.addLane()
  end

  if selectedLaneIndex > 0 then
    im.SameLine()
    if im.Button("Remove") then
      M.removeSelectedLane()
    end

    im.SameLine()
    if im.Button("Save") then
      local lane = M.getSelectedLane()
      if lane then
        M.saveLane(lane)
      end
    end
  end

  im.NewLine()

  for i, lane in ipairs(allLanes) do
    local isSelected = i == selectedLaneIndex
    local label = string.format("%s (%s)", lane.name or "Unnamed", lane.color or "unknown")

    if im.Selectable1(label, isSelected) then
      M.selectLane(i)
    end

    if im.IsItemHovered() then
      im.tooltip(string.format("ID: %s\nShort Name: %s\nLong Name: %s\nOrder: %d",
        lane.id or "N/A",
        lane.shortName or "N/A",
        lane.longName or "N/A",
        lane.laneOrder or 0))
    end
  end

  im.EndChild()
end

M.drawLaneDetails = function()
  local lane = M.getSelectedLane()
  if not lane then
    return
  end

  im.BeginChild1("laneDetails", im.ImVec2(0, 0), true)
  local li = tostring(M.getSelectedLaneIndex())
  local laneTitle = lane.name or lane.id or ("Lane " .. li)
  im.Spacing()
  if not utils.dragSectionHeader(laneTitle, "##laneDetailsRoot" .. li, true) then
    im.EndChild()
    return
  end

  im.Spacing()
  if utils.dragSectionHeader("Basics", "##laneDetailsBasics" .. li, true) then
  im.Text("ID: ")
  im.SameLine()
  local id = im.ArrayChar(256, lane.id or "")
  if im.InputText("##laneId", id, 256) then
    lane.id = ffi.string(id)
    utils.markUnsavedChanges()
  end

  im.Text("Name: ")
  im.SameLine()
  local name = im.ArrayChar(256, lane.name or "")
  if im.InputText("##laneName", name, 256) then
    lane.name = ffi.string(name)
    utils.markUnsavedChanges()
  end

  im.Text("Short Name: ")
  im.SameLine()
  local shortName = im.ArrayChar(256, lane.shortName or "")
  if im.InputText("##laneShortName", shortName, 256) then
    lane.shortName = ffi.string(shortName)
    utils.markUnsavedChanges()
  end

  im.Text("Long Name: ")
  im.SameLine()
  local longName = im.ArrayChar(256, lane.longName or "")
  if im.InputText("##laneLongName", longName, 256) then
    lane.longName = ffi.string(longName)
    utils.markUnsavedChanges()
  end

  im.Text("Color: ")
  im.SameLine()
  im.PushItemWidth(100)
  local colors = {"blue", "red", "green", "yellow", "purple", "orange"}
  local search = state.getSearch()
    local selectedColor = search:beginSearchableSimpleCombo(im, "laneColor##laneDetails" .. li, lane.color or "blue", colors)
  if selectedColor then
    lane.color = selectedColor
    utils.markUnsavedChanges()
  end
  im.PopItemWidth()

  im.Text("Lane Order: ")
  im.SameLine()
  local laneOrder = im.IntPtr(lane.laneOrder or 1)
  if im.InputInt("##laneOrder", laneOrder) then
    lane.laneOrder = laneOrder[0]
    utils.markUnsavedChanges()
  end

  end

  im.Spacing()
  if utils.dragSectionHeader("Waypoints", "##laneDetailsWps" .. li, true) then
    im.TextWrapped("BeamNGWaypoints come from the strip prefab. Open the strip in Drag Race Editor to see any missing scene names.")
  end

  im.Spacing()
  if utils.dragSectionHeader("Boundary", "##laneDetailsBoundary" .. li, true) then
  im.Text("Boundary ID: ")
  im.SameLine()
  local boundaryId = im.ArrayChar(256, lane.boundaryId or "")
  if im.InputText("##laneBoundaryId", boundaryId, 256) then
    lane.boundaryId = ffi.string(boundaryId)
    utils.markUnsavedChanges()
  end

  end

  im.Spacing()
  im.EndChild()
end

M.drawTransformsPreview = function()
  local lane = M.getSelectedLane()
  if not lane then return end

  debugDrawer:drawTextAdvanced(vec3(0, 0, 0), String("Lane: " .. lane.name), constants.CONSTANTS.COLORS.WHITE, true, false, constants.CONSTANTS.COLORS.BLACK)
end

M.drawAxisBox = function(corner, x, y, z, clr)
  for _, face in ipairs({{x,y,z},{x,z,y},{y,z,x}}) do
    local a,b,c = face[1],face[2],face[3]
    debugDrawer:drawLine((corner    ), (corner+c    ), ColorF(0,0,0,0.75))
    debugDrawer:drawLine((corner+a  ), (corner+c+a  ), ColorF(0,0,0,0.75))
    debugDrawer:drawLine((corner+b  ), (corner+c+b  ), ColorF(0,0,0,0.75))
    debugDrawer:drawLine((corner+a+b), (corner+c+a+b), ColorF(0,0,0,0.75))
    debugDrawer:drawTriSolid(
      vec3(corner    ),
      vec3(corner+a  ),
      vec3(corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(corner+b  ),
      vec3(corner    ),
      vec3(corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(corner+a  ),
      vec3(corner    ),
      vec3(corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(corner    ),
      vec3(corner+b  ),
      vec3(corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(c+corner    ),
      vec3(c+corner+a  ),
      vec3(c+corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(c+corner+b  ),
      vec3(c+corner    ),
      vec3(c+corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(c+corner+a  ),
      vec3(c+corner    ),
      vec3(c+corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(c+corner    ),
      vec3(c+corner+b  ),
      vec3(c+corner+a+b),
      clr)
  end
end

return M
