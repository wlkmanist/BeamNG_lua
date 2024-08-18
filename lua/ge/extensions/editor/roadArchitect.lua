-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Module constants.
local spinTime = 0.05                                                                               -- The amount of time between each profile auditioner rotation, in seconds.
local placeRotAngFac = 0.001                                                                        -- A angular factor used when rotating prefab groups, during placement.
local doubleClickTime = 200                                                                         -- The temporal tolerance used when determining a mouse double click, in ms.
local dragStartTime = 300                                                                           -- The amount of time after clicking the left mouse, at which dragging will start.
local mouseMoveTol = 1e-2                                                                           -- A tolerance used for determining if the mouse has moved since the last frame.
local tempFilepath = 'temp/roadArchitect.json'                                                      -- The path of the temporary file used when serialising/deserialising.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}


-- Check for a Tech license.
local isTechLicense = tech_license.isValid()

-- External modules used.
local roadMgr = require('editor/tech/roadArchitect/roads')                                          -- A module for managing the road structure/handling road calculations.
local profileMgr = require('editor/tech/roadArchitect/profiles')                                    -- A module for managing the profiles structure/handling profile calculations.
local groupMgr = require('editor/tech/roadArchitect/groups')                                        -- A module for managing the prefab groups.
local linkMgr = require('editor/tech/roadArchitect/links')                                          -- A module for managing the link structure.
local geom = require('editor/tech/roadArchitect/geometry')                                          -- A module for performing geometric calculations.
local render = require('editor/tech/roadArchitect/render')                                          -- A module for managing the rendering of roads (debugDrawer visualisations).
local terra = require('editor/tech/roadArchitect/terraform')                                        -- A module for handling terraforming operations.
local util = require('editor/tech/roadArchitect/utilities')                                         -- A module containing miscellaneous utility functions.
local import, export = nil, nil
if isTechLicense then
  import = require('editor/tech/roadArchitect/import')                                              -- A module for importing road networks.
  export = require('editor/tech/roadArchitect/export')                                              -- A module for exporting road networks.
end

-- Module constants (core).
local im = ui_imgui
local abs, min, max, floor, ceil = math.abs, math.min, math.max, math.floor, math.ceil
local sin, cos = math.sin, math.cos

-- Module constants (UI).
local toolWinName, toolWinSize = 'roadArchitect', im.ImVec2(530, 45)                                -- The main tool window of the editor. The main UI entry point.
local roadsListWinName, roadsListWinSize = 'RoadsListWindow', im.ImVec2(212, 280)                   -- The roads list window (primary window). Shows all active roads.
local roadEditWinName, roadEditWinSize = 'RoadEditWindow', im.ImVec2(246, 550)                      -- The individual road editor window (secondary window). Shows single road.
local nodeEditWinName, nodeEditWinSize = 'NodeEditWindow', im.ImVec2(712, 310)                      -- The individual road node editor window (secondary window).
local profilesListWinName, profilesListWinSize = 'ProfilesListWindow', im.ImVec2(230, 249)          -- The lateral road profiles list window (primary window).
local profileEditWinName, profileEditWinSize = 'ProfileEditWindow', im.ImVec2(845, 490)             -- The lateral road profile editor window (secondary window).
local groupsListWinName, groupsListWinSize = 'GroupsListWindow', im.ImVec2(230, 249)                -- The groups list window (secondary window).
local importWinName, importWinSize = 'ImportOptionsWindow', im.ImVec2(230, 200)                     -- The import options window (secondary window).
local vec19, vec21, vec22 = im.ImVec2(19, 19), im.ImVec2(21, 21), im.ImVec2(22, 22)                 -- Some commonly-used Imgui vectors.
local vec27, vec28, vec34 = im.ImVec2(27, 27), im.ImVec2(28, 28), im.ImVec2(34, 34)
local dullWhite = im.ImVec4(1, 1, 1, 0.5)                                                           -- Some commonly-used Imgui colour vectors.
local darkLockCol = im.ImVec4(0.05, 0.05, 0.05, 1.0)
local unlinkCol = im.ImVec4(0.75, 0.75, 0.75, 1.0)
local redB, redD = im.ImVec4(0.7, 0.5, 0.5, 1), im.ImVec4(0.7, 0.5, 0.5, 0.5)
local greenB, greenD = im.ImVec4(0.5, 0.7, 0.5, 1), im.ImVec4(0.5, 0.7, 0.5, 0.5)
local blueB, blueD = im.ImVec4(0.5, 0.5, 0.7, 1), im.ImVec4(0.5, 0.5, 0.7, 0.5)
local violetB = im.ImVec4(0.7, 0.5, 0.7, 1)

-- Module state (back-end).
local isRoadArchitectActive = false                                                                 -- A flag which indicates if this editor is currently active.
local isLinkMode = false                                                                            -- A flag which indicates if the editor is in 'link mode', or not.
local isGroupPlaceMode = false                                                                      -- A flag which indicates if the editor is in 'group placement' mode, or not.
local isCreateGroup = false                                                                         -- A flag which indicates if the editor is in 'create group' mode, or not.
local isFinalise = false                                                                            -- A flag which indicates if decals have been laid/collision mesh built.
local isMultiSelect = false                                                                         -- A flag which indicates if the editor is in 'multi select draw polygon' mode, or not.
local isMultiDone = false                                                                           -- A flag which indicates if there is a multi-selection made, and can be manipulated.
local isBulldoze = false                                                                            -- A flag which indicates if the editor is in 'bulldoze mode', or not.
local isConformGroupToTerrain = false                                                               -- A flag which indicates if the group will be conformed to the terrain, or not.
local terrain = nil                                                                                 -- The terrain block, if if exists (used here only for testing existence).
local timer, mouseTimer = hptimer(), hptimer()
local time = 0.0                                                                                    -- The time state, in seconds.
local drag = {                                                                                      -- A table for storing data when the mouse is being dragged.
  isDrag = false,
  startPos = nil,
  road = nil, node = nil }
local heldTime = 0.0                                                                                -- The time which the mouse left button has been held for.
local pGroup = nil                                                                                  -- A group of roads which are to be placed by the user.
local gPolygon = {}                                                                                 -- A polygon used when creating new prefab groups.
local mouseLast = vec3(0, 0)                                                                        -- The last position of the mouse.
local timeSinceLastClick = 1e99                                                                     -- The time since the last left mouse click, in seconds.
local importCO, importTT2I, importO2T = im.BoolPtr(false), im.BoolPtr(false), im.BoolPtr(false)     -- Checkbox flags used for various importing options.
local importCustomOffset = im.FloatPtr(0.0)                                                         -- Custom offset used for importing.
local domainOfInfluence = im.IntPtr(150)                                                            -- The domain of influence, used for terraforming.
local tmp0, tmp1 = vec3(0, 0), vec3(0, 0)

-- Module state (front-end).
local isRoadsListWinOpen, isRoadEditWinOpen, isNodeEditWinOpen = false, false, false                -- Flags which indicates if the sub-windows are open or closed.
local isProfilesListWinOpen, isProfileEditWinOpen, isGroupsListWinOpen = false, false, false
local isImportWinOpen = false
local selectedRoadIdx, selectedNodeIdx = 1, 1                                                       -- Listbox selection index values.
local selectedProfileIdx, selectedLaneIdx, selectedGroupIdx = 1, 1, 1


-- Undo callback for road edits.
local function editRoadUndo(data)
  local rIdx = roadMgr.map[data.old.name]
  if rIdx and roadMgr.roads[rIdx] then
    roadMgr.roads[rIdx] = data.old
  else
    roadMgr.roads[#roadMgr.roads + 1] = data.old                                                    -- If the road has been deleted, create a new road.
    roadMgr.recomputeMap()
  end
end

-- Redo callback for road edits.
local function editRoadRedo(data)
  if data.new and roadMgr.map[data.new.name] and roadMgr.roads[roadMgr.map[data.new.name]] then
    roadMgr.roads[roadMgr.map[data.new.name]] = data.new
  else
    roadMgr.roads[#roadMgr.roads + 1] = data.new                                                    -- If the road has been deleted, create a new road.
    roadMgr.recomputeMap()
  end
end

-- The callback functions for begin/end axis gizmo dragging.
local function gizmoBeginDrag() end
local function gizmoEndDrag() end

-- The callback function for continuing axis gizmo dragging.
local function gizmoDragging()
  if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then                               -- Handle dragging on the translation gizmo.
    if selectedRoadIdx and selectedNodeIdx then
      local roads = roadMgr.roads
      local road = roads[selectedRoadIdx]
      if road then
        local nodes = road.nodes
        local node = nodes[selectedNodeIdx]
        if node then
          local gPoint = editor.getAxisGizmoTransform():getColumn(3)

          if isMultiDone then                                                                       -- CASE A: [Multi Select].
            local trVec = gPoint - node.p
            local multi = roadMgr.multi
            for i = 1, #multi do
              local m = multi[i]
              roads[m.r].nodes[m.n].p = roads[m.r].nodes[m.n].p + trVec
              roadMgr.setDirty(roads[m.r])
            end

          elseif node.p:squaredDistance(gPoint) > 1e-3 then                                         -- CASE B: [Single Select].
            local roadPre = roadMgr.copyRoad(road)
            if road.isRigidTranslation[0] and not node.isLocked then
              local v = gPoint - node.p
              local numNodes = #nodes
              for i = 1, numNodes do
                if not nodes[i].isLocked then
                  nodes[i].p = nodes[i].p + v
                end
              end
            else
              if road.isArc and selectedNodeIdx == 2 then                                           -- Arc middle points cannot move vertically.
                node.p:set(gPoint.x, gPoint.y, node.p.z)
              else
                node.p = editor.getAxisGizmoTransform():getColumn(3)
              end
            end
            roadMgr.setDirty(road)
            local roadPost = roadMgr.copyRoad(road)
            editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
          end

        end
      end
    end
  end
end

-- Handles the gimbals for translation.
local function handleGimbals(pos)
  if not isGroupPlaceMode and not isGroupsListWinOpen then
    local rotation = QuatF(0, 0, 0, 1)
    local transform = rotation:getMatrix()
    transform:setPosition(pos)
    editor.setAxisGizmoTransform(transform)
    editor.updateAxisGizmo(gizmoBeginDrag, gizmoEndDrag, gizmoDragging)
    editor.drawAxisGizmo()
  end
end

-- Gets the first (non-hidden) road index.
local function getFirstRoadIdx()
  local roads = roadMgr.roads
  local numRoads = #roads
  for i = 1, numRoads do
    if not roads[i].isHidden then
      return i
    end
  end
  return nil
end

-- Gets the last (non-hidden) road index.
local function getLastRoadIdx()
  local roads = roadMgr.roads
  for i = #roads, 1, -1 do
    if not roads[i].isHidden then
      return i
    end
  end
  return nil
end

-- Gets the selected road index, from a given UI listbox index.
local function getSelRoadIdx(iLB)
  local roads = roadMgr.roads
  local numRoads, ctr = #roads, 0
  for i = 1, numRoads do
    if not roads[i].isHidden then
      ctr = ctr + 1
      if ctr == iLB then
        return i
      end
    end
  end
  return getFirstRoadIdx()
end

-- Closes all open windows related to the editor.
local function closeAllWindows()
  if isProfilesListWinOpen then
    editor.hideWindow(profilesListWinName)
    isProfilesListWinOpen = false
    profileMgr.goToOldView()
    roadMgr.removeHiddenRoads()
  end
  if isGroupsListWinOpen then
    editor.hideWindow(groupsListWinName)
    isGroupsListWinOpen = false
    groupMgr.goToOldView()
    roadMgr.removeHiddenRoads()
  end
  if isProfileEditWinOpen then
    editor.hideWindow(profileEditWinName)
    isProfileEditWinOpen = false
  end
  if isRoadEditWinOpen then
    editor.hideWindow(roadEditWinName)
    isRoadEditWinOpen = false
  end
  if isNodeEditWinOpen then
    editor.hideWindow(nodeEditWinName)
    isNodeEditWinOpen = false
  end
  if isRoadsListWinOpen then
    editor.hideWindow(roadsListWinName)
    isRoadsListWinOpen = false
  end
end

-- Handles the creation of roads.
local function handleCreateRoads(roads, mousePos, isMouseClickedL, isMouseDownL, isDoubleClick, hasMouseBeenDownAWhile)

  -- Handle any current mouse dragging.
  if drag.isDrag then
    local dragRoad = roads[drag.road]
    local pCurrent = dragRoad.nodes[drag.node].p                                                    -- Manage the translating of roads.
    if mousePos:squaredDistance(pCurrent) > 1e-3 and util.isMouseHoveringOverTerrain() then
      local roadPre = roadMgr.copyRoad(dragRoad)
      roadMgr.moveRoad(dragRoad, drag.node, mousePos, mouseLast)                                    -- Add new nodes to the road, if the mouse is clicked.
      local roadPost = roadMgr.copyRoad(dragRoad)
      editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
      roadMgr.setDirty(dragRoad)
    end
    if not isMouseDownL then                                                                        -- If mouse is released, deactivate the drag state.
      drag.isDrag, drag.startPos, drag.road, drag.node = false, nil, nil, nil
    end
  end

  -- Handle the mouse actions.
  local isOverNode, rIdx, nIdx = util.isMouseOverNode(roads)
  if util.isMouseHoveringOverTerrain() then
    if isOverNode then                                                                              -- [If mouse is over a (non-hidden) road node].
      local road = roads[rIdx]
      if not road.isHidden and not road.isLinkRoad then
        local hNode = road.nodes[nIdx]
        util.drawSphereHighlight(hNode.p)
        selectedRoadIdx, selectedNodeIdx = rIdx, nIdx                                               -- Select the road/node so it appears in the ui windows.
        if hasMouseBeenDownAWhile and not drag.isDrag then                                          -- If mouse held over node.
          drag.isDrag, drag.startPos, drag.road, drag.node = true, hNode.p, rIdx, nIdx              -- This may be a mouse drag, so store the start conditions.
        end
        if isOverNode and isMouseClickedL then                                                      -- If user clicks over a node, ensure the road windows are open.
          if not isRoadsListWinOpen then
            editor.showWindow(roadsListWinName)
            isRoadsListWinOpen = true
          end
          if not isRoadEditWinOpen then
            editor.showWindow(roadEditWinName)
            isRoadEditWinOpen = true
          end
        end
      end
    elseif isRoadEditWinOpen then                                                                   -- [If mouse is over the *empty* terrain].
      local road = roads[selectedRoadIdx]
      if selectedRoadIdx and road then
        if not road.isLinkRoad and not (road.isArc and #road.nodes > 2) then                        -- User cannot add new nodes on link roads, or more than 3 on arcs.
          util.drawSphere(mousePos)                                                                 -- Draw a sphere around the mouse position on the terrain.
          if isMouseClickedL then
            local roadPre = roadMgr.copyRoad(road)
            roadMgr.addNodeToRoad(selectedRoadIdx, mousePos)                                        -- Add new nodes to the road, if the mouse is clicked.
            local roadPost = roadMgr.copyRoad(road)
            editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
          end
        end
      end
    end
  end
end

-- Handles the logic of lane start/end selection and creating links between roads.
local function handleLinks(roads, link, isMouseClickedL)

  -- Do not have any sub-windows open when user is creating a link proposal.
  -- [This is to avoid removing any proposed roads while the link proposal is being built].
  closeAllWindows()

  -- Cache the link properties.
  local isActive = link.isActive
  local r1Name, r1Lie, l1 = link.r1Name, link.r1Lie, link.l1
  local r2Name, r2Lie, l2 = link.r2Name, link.r2Lie, link.l2

  -- Determine if the mouse is hovering over a road lane start/end points, and in which manner.
  local isOverStart, isOverEnd, rIdx, rName, lIdx = util.isMouseOverLaneEnd(roads)
  local road = roads[rIdx]

  -- Test if the mouse is hovering over a road lane start point.
  if isOverStart and not road.isLinkRoad then
    local sPos = road.renderData[1][lIdx][7]
    if not isActive then
      util.drawSphereHighlight(sPos)                                                                -- Link does not exist yet, so activate it with road 1.
      if isMouseClickedL then
        link.isActive, link.r1Name, link.r1Lie, link.l1[lIdx] = true, rName, 'start', true
      end
    else                                                                                            -- Link has a first road and is active.
      if rName == r1Name and r1Lie == 'start' and link.l1[lIdx] then
        util.drawSphereHighlight(sPos)
        if isMouseClickedL then
          linkMgr.removeLaneFromLink(lIdx, 1, link)                                                 -- Lane already selected, so remove it (if not bounded).
          return
        end
      elseif rName == r2Name and r2Lie == 'start' and l2[lIdx] then
        util.drawSphereHighlight(sPos)
        if isMouseClickedL then
          linkMgr.removeLaneFromLink(lIdx, 2, link)                                                 -- Lane already selected, so remove it (if not bounded).
          return
        end
      elseif rName == r1Name and r1Lie == 'start' and linkMgr.isLaneAdjacent(lIdx, l1, roads[rIdx].nodes[1]) then
        util.drawSphereHighlight(sPos)                                                              -- Potentially add an adjacent lane to link road 1.
        if isMouseClickedL then
          link.l1[lIdx] = true
        end
      elseif not r2Name then
        util.drawSphereHighlight(sPos)                                                              -- Potentially add a road 2 to a link with only road 1.
        if isMouseClickedL then
          link.r2Name, link.r2Lie, link.l2[lIdx] = rName, 'start', true
        end
      elseif rName == r2Name and r2Lie == 'start' and linkMgr.isLaneAdjacent(lIdx, l2, roads[rIdx].nodes[1]) then
        util.drawSphereHighlight(sPos)                                                              -- Link has road 1 and 2, so add adjacent lane to road 2.
        if isMouseClickedL then
          link.l2[lIdx] = true
        end
      end
    end

  -- Test if the mouse is hovering over a road lane end point.
  elseif isOverEnd and not road.isLinkRoad then
    local sPos = road.renderData[#road.renderData][lIdx][7]
    if not isActive then
      util.drawSphereHighlight(sPos)                                                                -- Link does not exist yet, so activate it with road 1.
      if isMouseClickedL then
        link.isActive, link.r1Name, link.r1Lie, link.l1[lIdx] = true, rName, 'end', true
      end
    else                                                                                            -- Link has a first road and is active.
      if rName == r1Name and r1Lie == 'end' and l1[lIdx] then
        util.drawSphereHighlight(sPos)
        if isMouseClickedL then
          linkMgr.removeLaneFromLink(lIdx, 1, link)                                                 -- Lane already selected, so remove it (if not bounded).
          return
        end
      elseif rName == r2Name and r2Lie == 'end' and l2[lIdx] then
        util.drawSphereHighlight(sPos)
        if isMouseClickedL then
          linkMgr.removeLaneFromLink(lIdx, 2, link)                                                 -- Lane already selected, so remove it (if not bounded).
          return
        end
      elseif rName == r1Name and r1Lie == 'end' and linkMgr.isLaneAdjacent(lIdx, l1, road.nodes[#road.nodes]) then
        util.drawSphereHighlight(sPos)                                                              -- Potentially add an adjacent lane to link road 1.
        if isMouseClickedL then
          link.l1[lIdx] = true
        end
      elseif not r2Name then
        util.drawSphereHighlight(sPos)                                                              -- Potentially add a road 2 to a link with only road 1.
        if isMouseClickedL then
          link.r2Name, link.r2Lie, link.l2[lIdx] = rName, 'end', true
        end
      elseif rName == r2Name and r2Lie == 'end' and linkMgr.isLaneAdjacent(lIdx, l2, road.nodes[#road.nodes]) then
        util.drawSphereHighlight(sPos)                                                              -- Link has road 1 and 2, so add adjacent lane to road 2.
        if isMouseClickedL then
          link.l2[lIdx] = true
        end
      end
    end
  end
end

-- Computes the centroid of the collection of roads stored in the placing group array.
-- [The centroid is only on the XY-plane.  In Z, we use the minimum to ensure whole group appears above mouse height].
local function getPlacingGroupCentroid(roads)
  local pGroupLen, map = #pGroup, roadMgr.map
  local xMin, xMax, yMin, yMax, zMin, zMax = 1e99, -1e99, 1e99, -1e99, 1e99, -1e99
  for i = 1, pGroupLen do
    local r = roads[map[pGroup[i]]]
    local nodes = r.nodes
    local numNodes = #nodes
    for j = 1, numNodes do
      local p = nodes[j].p
      local x, y, z = p.x, p.y, p.z
      xMin, xMax, yMin, yMax, zMin, zMax = min(xMin, x), max(xMax, x), min(yMin, y), max(yMax, y), min(zMin, z), max(zMax, z)
    end
  end
  tmp0:set(xMin, yMin, zMin)
  tmp1:set(xMax, yMax, zMin)
  return tmp0 + 0.5 * (tmp1 - tmp0)
end

-- Handles the placing of prefab groups.
local function handlePlaceGroup(roads, mousePos, isDoubleClick, isMouseDownL, isMouseClickedR)

  -- Prefab group placing functionality:
  -- i)   If the user moves the mouse freely (no button held), the candidate group will move with the mouse.
  -- ii)  If the user holds down the left mouse button, moving the mouse (in Y) will rotate the group.
  -- iii) If the user double-clicks the left mouse button, the group will be placed and we leave the group placing edit mode.
  -- iv)  If the user right-clicks the mouse, the group will be removed and the editor will revert to its normal state.
  if isDoubleClick then
    isGroupPlaceMode, pGroup = false, nil
    return
  end

  if isMouseClickedR then
    local pGroupLen = #pGroup
    for i = 1, pGroupLen do
      roadMgr.removeRoad(pGroup[i])
    end
    table.clear(pGroup)
    isGroupPlaceMode = false
  end

  if isMouseDownL then
    local dy = mousePos.y - mouseLast.y
    if abs(dy) > 1e-3 then
      local theta = sign2(dy) * max(10.0, abs(dy)) * placeRotAngFac
      local cen = getPlacingGroupCentroid(roads)
      local map, pGroupLen = roadMgr.map, #pGroup
      for i = 1, pGroupLen do
        local r = roads[map[pGroup[i]]]
        local nodes = r.nodes
        local numNodes = #nodes
        for j = 1, numNodes do
          local n = nodes[j]
          local zOld = n.p.z
          local p = n.p - cen
          local x, y, s, c = p.x, p.y, sin(theta), cos(theta)
          n.p:set(x * c - y * s + cen.x, x * s + y * c + cen.y, zOld)
        end
        roadMgr.setDirty(r)
      end
    end
  elseif util.isMouseHoveringOverTerrain() and mousePos:squaredDistance(mouseLast) > mouseMoveTol then
    local offset = mousePos - getPlacingGroupCentroid(roads)
    local map, pGroupLen = roadMgr.map, #pGroup
    for i = 1, pGroupLen do
      local r = roads[map[pGroup[i]]]
      local nodes = r.nodes
      local numNodes = #nodes
      for j = 1, numNodes do
        local n = nodes[j]
        n.p = n.p + offset
        n.height = im.FloatPtr(n.p.z)
      end
      roadMgr.setDirty(r)
    end
  end
end

-- Handles the creation of a bulldoze polygon.
-- [Allows user to draw a polygon around roads, using mouse clicks, then double-click to complete and create selection].
  local function handleBulldoze(roads, mousePos, isMouseClickedL, isDoubleClick, isMouseClickedR)
    util.drawGroupSphere(mousePos)                                                                    -- Draw a sphere at the mouse position.
    local gPolygonLen = #gPolygon
    if isMouseClickedR then                                                                           -- Clicking the right mouse button clears the polygon.
      table.clear(gPolygon)
    elseif isDoubleClick and gPolygonLen > 2 then                                                     -- Double-clicking the left mouse button closes the polygon/creates the selection.
      gPolygon[#gPolygon + 1] = gPolygon[1]
      roadMgr.bulldoze(gPolygon)
      table.clear(gPolygon)
      isBulldoze = false
    elseif isMouseClickedL then                                                                       -- Single-clicking the left mouse button adds another vertex to the polygon.
      gPolygon[#gPolygon + 1] = mousePos
    end
  end

-- Handles the creation of a multi-select polygon.
-- [Allows user to draw a polygon around roads, using mouse clicks, then double-click to complete and create selection].
local function handleMultiSelect(roads, mousePos, isMouseClickedL, isDoubleClick, isMouseClickedR)
  util.drawGroupSphere(mousePos)                                                                    -- Draw a sphere at the mouse position.
  local gPolygonLen = #gPolygon
  if isMouseClickedR then                                                                           -- Clicking the right mouse button clears the polygon.
    table.clear(gPolygon)
  elseif isDoubleClick and gPolygonLen > 2 then                                                     -- Double-clicking the left mouse button closes the polygon/creates the selection.
    gPolygon[#gPolygon + 1] = gPolygon[1]
    roadMgr.createMultiSelect(gPolygon)
    table.clear(gPolygon)
    isMultiDone = true
    local first = roadMgr.multi[1]
    selectedRoadIdx, selectedNodeIdx = first.r, first.n
  elseif isMouseClickedL then                                                                       -- Single-clicking the left mouse button adds another vertex to the polygon.
    gPolygon[#gPolygon + 1] = mousePos
  end
end

-- Handles the creation of new prefab groups.
-- [Allows user to draw a polygon around roads, using mouse clicks, then double-click to complete and create group].
local function handleCreateGroup(roads, mousePos, isMouseClickedL, isDoubleClick, isMouseClickedR)
  util.drawGroupSphere(mousePos)                                                                    -- Draw a sphere at the mouse position.
  local gPolygonLen = #gPolygon
  if isMouseClickedR then                                                                           -- Clicking the right mouse button clears the polygon.
    table.clear(gPolygon)
  elseif isDoubleClick and gPolygonLen > 2 then                                                     -- Double-clicking the left mouse button closes the polygon/creates the group.
    gPolygon[#gPolygon + 1] = gPolygon[1]
    groupMgr.createGroup(gPolygon, roads)
    table.clear(gPolygon)
    isCreateGroup = false
  elseif isMouseClickedL then                                                                       -- Single-clicking the left mouse button adds another vertex to the polygon.
    gPolygon[#gPolygon + 1] = mousePos
  end
end

-- Handles the laying/unlaying of decals.
local function handleisFinalise()
  if isFinalise then
    if isRoadsListWinOpen then
      editor.hideWindow(roadsListWinName)
      isRoadsListWinOpen = false
    end
    if isRoadEditWinOpen then
      editor.hideWindow(roadEditWinName)
      isRoadEditWinOpen = false
    end
    if isNodeEditWinOpen then
      editor.hideWindow(nodeEditWinName)
      isNodeEditWinOpen = false
    end
    local wasProfileOpen = isProfilesListWinOpen or isProfileEditWinOpen
    if isProfilesListWinOpen then
      editor.hideWindow(profilesListWinName)
      isProfilesListWinOpen = false
    end
    if isProfileEditWinOpen then
      editor.hideWindow(profileEditWinName)
      isProfileEditWinOpen = false
    end
    if wasProfileOpen then
      profileMgr.goToOldView()
      roadMgr.removeHiddenRoads()
    end
    if isGroupsListWinOpen then
      editor.hideWindow(groupsListWinName)
      isGroupsListWinOpen = false
      groupMgr.goToOldView()
      roadMgr.removeHiddenRoads()
    end
    roadMgr.finalise()                                                                              -- Switch to the 'finalise' state.
  else
    roadMgr.unfinalise()                                                                            -- Revert to the 'edit' state.
  end
end

-- Updates a road to take on a new profile template.
local function updateRoadToNewProfile()
  local road = roadMgr.roads[selectedRoadIdx]
  local roadPre = roadMgr.copyRoad(road)
  local profile = profileMgr.profiles[selectedProfileIdx]
  local profileName = profile.name
  profileMgr.updateToNewTemplate(road, profileName)
  road.laneKeys, road.leftKeys, road.rightKeys = profileMgr.computeLaneKeys(profile)
  roadMgr.updateWAndHToNewProfile(road)
  roadMgr.setDirty(road)
  local roadPost = roadMgr.copyRoad(road)
  editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
end

-- Saves the current editor session to disk.
local function saveSession()
  extensions.editor_fileDialog.saveFile(
    function(data)

      local serRoads, serProfiles, serGroups = {}, {}, {}
      local roads, profiles, groups = roadMgr.roads, profileMgr.profiles, groupMgr.groups
      local numRoads, numProfiles, numGroups = #roads, #profiles, #groups

      -- Serialise all the roads data.
      for i = 1, numRoads do
        serRoads[i] = roadMgr.serialiseRoad(roads[i])
      end

      -- Serialise all the lateral profile data.
      for i = 1, numProfiles do
        serProfiles[i] = profileMgr.serialiseProfile(profiles[i])
      end

      -- Serialise all the prefab group data.
      for i = 1, numGroups do
        serGroups[i] = groupMgr.serialiseGroup(groups[i])
      end

      local encodedData = { data = lpack.encode({
        roads = serRoads,
        profiles = serProfiles,
        groups = serGroups,
        history = terra.history })}
      jsonWriteFile(data.filepath, encodedData, true)
    end,
    {{"JSON",".json"}},
    false,
    "/",
    "File already exists.\nDo you want to overwrite the file?")
end

-- Loads a previously-saved editor session from disk.
local function loadSession()
  extensions.editor_fileDialog.openFile(
    function(data)

      -- Remove all meshes and decals from scene.
      roadMgr.removeAll()

      -- Collect the loaded data.
      local loadedJson = jsonReadFile(data.filepath)
      local data = lpack.decode(loadedJson.data)
      local serRoads, serProfiles, serGroups = data.roads, data.profiles, data.groups
      local numRoads, numProfiles, numGroups = #serRoads, #serProfiles, #serGroups

      -- Recover the terrain terraform state from the saved session.
      terra.applyHistoryOnLoad(data.history)

      -- De-serialise all the stored profiles, into the profiles container.
      table.clear(profileMgr.profiles)
      for i = 1, numProfiles do
        profileMgr.profiles[i] = profileMgr.deserialiseProfile(serProfiles[i])
      end

      -- De-serialise all the stored roads, into the roads container.
      table.clear(roadMgr.roads)
      for i = 1, numRoads do
        roadMgr.roads[i] = roadMgr.deserialiseRoad(serRoads[i])
      end
      roadMgr.recomputeMap()

      -- De-serialise all the stored prefab groups, into the prefab groups container.
      table.clear(groupMgr.groups)
      for i = 1, numGroups do
        groupMgr.groups[i] = groupMgr.deserialiseGroup(serGroups[i])
      end

      -- Compute the render data for all roads.
      roadMgr.computeAllRoadRenderData()
    end,
    {{"JSON",".json"}},
    false,
    "/")
end

-- Handles the main tool window.
local function handleMainToolWindow(roads, link)
  if editor.beginWindow(toolWinName, "Road Architect###8", im.WindowFlags_NoTitleBar) then

    -- Buttons row.
    im.Columns(13, "toolWindowColsBottom", false)
    im.SetColumnWidth(0, 40)
    im.SetColumnWidth(1, 40)
    im.SetColumnWidth(2, 40)
    im.SetColumnWidth(3, 40)
    im.SetColumnWidth(4, 40)
    im.SetColumnWidth(5, 40)
    im.SetColumnWidth(6, 40)
    im.SetColumnWidth(7, 40)
    im.SetColumnWidth(8, 40)
    im.SetColumnWidth(9, 40)
    im.SetColumnWidth(10, 40)
    im.SetColumnWidth(11, 40)
    im.SetColumnWidth(12, 40)

    -- Toggle 'Open/Close Roads List Window'  button.
    if not isFinalise and not isLinkMode and not isProfilesListWinOpen and not isGroupsListWinOpen and not isCreateGroup and not isMultiSelect and not isBulldoze and not isGroupPlaceMode then
      local roadButtonCol = blueD
      if isRoadsListWinOpen then roadButtonCol = blueB end
      if editor.uiIconImageButton(editor.icons.autobahn, vec34, roadButtonCol, nil, nil, 'toggleRoadsListWindow') then
        if isRoadsListWinOpen then
          editor.hideWindow(roadsListWinName)
        else
          editor.showWindow(roadsListWinName)
        end
        isRoadsListWinOpen = not isRoadsListWinOpen
      end
      im.tooltip('Open/close the roads list window.')
    end
    im.SameLine()
    im.NextColumn()

    -- 'Bulldoze' button.
    if not isProfilesListWinOpen and not isLinkMode and not isGroupsListWinOpen and not isCreateGroup and not isGroupPlaceMode and not isMultiSelect and not isFinalise then
      local bulldozeButtonCol = blueD
      if isBulldoze then bulldozeButtonCol = blueB end
      if editor.uiIconImageButton(editor.icons.bulldozer, vec34, bulldozeButtonCol, nil, nil, 'BulldozeButton') then
        isBulldoze = not isBulldoze
        if isBulldoze then
          closeAllWindows()
          table.clear(gPolygon)
        end
      end
      im.tooltip('Bulldoze multiple nodes/roads, by drawing a polygon.')
    end
    im.SameLine()
    im.NextColumn()

    -- 'Multi Select' button.
    if not isProfilesListWinOpen and not isLinkMode and not isGroupsListWinOpen and not isCreateGroup and not isGroupPlaceMode and not isBulldoze and not isFinalise then
      local multiSelectButtonCol = blueD
      if isMultiSelect then multiSelectButtonCol = blueB end
      if editor.uiIconImageButton(editor.icons.forest_select, vec34, multiSelectButtonCol, nil, nil, 'MultiSelectButton') then
        isMultiSelect = not isMultiSelect
        if isMultiSelect then
          closeAllWindows()
          table.clear(gPolygon)
        end
        if not isMultiSelect then
          isMultiDone = false
        end
      end
      im.tooltip('Multi-select multiple nodes/roads, by drawing a polygon.')
    end
    im.SameLine()
    im.NextColumn()

    -- 'Is Finalise' button.
    if not isGroupsListWinOpen and not isLinkMode and not isProfilesListWinOpen and not isCreateGroup and not isMultiSelect and not isBulldoze and not isGroupPlaceMode then
      local layDecalsButtonCol = blueD
      local finIcon = editor.icons.lock_open
      if isFinalise then layDecalsButtonCol, finIcon = blueB, editor.icons.lock end
      if editor.uiIconImageButton(finIcon, vec34, layDecalsButtonCol, nil, nil, 'LayDecalsButton') then
        isFinalise = not isFinalise
        handleisFinalise()
      end
      im.tooltip('Toggle between Edit Mode and Finalize Mode.')
    end
    im.SameLine()
    im.NextColumn()

    -- 'Groups' button.
    if not isProfilesListWinOpen and not isLinkMode and not isCreateGroup and not isGroupPlaceMode and not isMultiSelect and not isBulldoze and not isFinalise then
    local groupsButtonCol = greenD
    if isGroupsListWinOpen then groupsButtonCol = greenB end
      if editor.uiIconImageButton(editor.icons.group, vec34, groupsButtonCol, nil, nil, 'GroupsButton') then
        isGroupsListWinOpen = not isGroupsListWinOpen
        if isRoadsListWinOpen then
          editor.hideWindow(roadsListWinName)
          isRoadsListWinOpen = false
        end
        if isRoadEditWinOpen then
          editor.hideWindow(roadEditWinName)
          isRoadEditWinOpen = false
        end
        if isNodeEditWinOpen then
          editor.hideWindow(nodeEditWinName)
          isNodeEditWinOpen = false
        end
        if isProfileEditWinOpen then
          editor.hideWindow(profileEditWinName)
          isProfileEditWinOpen = false
        end
        if isProfilesListWinOpen then
          editor.hideWindow(profilesListWinName)
          isProfilesListWinOpen = false
          profileMgr.goToOldView()
          roadMgr.removeHiddenRoads()
        end
        if isGroupsListWinOpen then
          editor.showWindow(groupsListWinName)
          roadMgr.removeHiddenRoads()
          groupMgr.addGroupToRoadsAudition(selectedGroupIdx)
        else
          editor.hideWindow(groupsListWinName)
          groupMgr.goToOldView()
          roadMgr.removeHiddenRoads()
        end
      end
      im.tooltip('Open/close the groups list window.')
    end
    im.SameLine()
    im.NextColumn()

    -- 'Create Group' button.
    if not isProfilesListWinOpen and not isLinkMode and not isGroupsListWinOpen and not isGroupPlaceMode and not isMultiSelect and not isBulldoze and not isFinalise then
      local createGroupButtonCol = greenD
      if isCreateGroup then createGroupButtonCol = greenB end
      if editor.uiIconImageButton(editor.icons.addPolygonVertex, vec34, createGroupButtonCol, nil, nil, 'CreateGroupButton') then
        isCreateGroup = not isCreateGroup
        if isCreateGroup then
          closeAllWindows()
          table.clear(gPolygon)
        end
      end
      im.tooltip('Create a new prefab group, by drawing a polygon.')
    end
    im.SameLine()
    im.NextColumn()

    -- 'Create A Link Proposal' button.
    if not isProfilesListWinOpen and not isGroupsListWinOpen and not isCreateGroup and not isGroupPlaceMode and not isMultiSelect and not isBulldoze and not isFinalise then
      local linkProposalColor = redD
      if isLinkMode then linkProposalColor = redB end
      if editor.uiIconImageButton(editor.icons.twoRoadsAdd, vec34, linkProposalColor, nil, nil, 'createRoadLinkage') then
        isLinkMode = not isLinkMode
        if not isLinkMode then
          linkMgr.clearLink()
        end
      end
      im.tooltip('Design a link between roads.')
    end
    im.SameLine()
    im.NextColumn()

    -- Link buttons.
    if not isProfilesListWinOpen and isLinkMode and not isGroupsListWinOpen and not isCreateGroup and not isGroupPlaceMode and not isMultiSelect and not isBulldoze and not isFinalise then

      -- 'Create Proposed Link' button.
      if link.isActive and linkMgr.isLinkValid(link) then
        if editor.uiIconImageButton(editor.icons.touch_app, vec34, redB, nil, nil, 'createProposedLink') then
          linkMgr.createLink(link)
          selectedRoadIdx = #roads
          isLinkMode = false
        end
        im.tooltip('Create the proposed link.')
        im.SameLine()
        im.NextColumn()
      else
        im.SameLine()
        im.NextColumn()
      end

      -- Clear current link button.
      if link.isActive then
        if editor.uiIconImageButton(editor.icons.content_cut, vec34, redB, nil, nil, 'clearLink') then
          linkMgr.clearLink()
          isLinkMode = false
        end
        im.tooltip('Clear the current link.')
        im.SameLine()
        im.NextColumn()
      else
        im.SameLine()
        im.NextColumn()
      end

    else
      im.SameLine()
      im.NextColumn()
      im.SameLine()
      im.NextColumn()
    end

    -- 'Import Road Network' button.
    if not isFinalise then
      if isTechLicense and editor.uiIconImageButton(editor.icons.ab_asset_jbeam, vec34, violetB, nil, nil, 'openImportWdw') then
        isImportWinOpen = not isImportWinOpen
        if isImportWinOpen then
          editor.showWindow(importWinName)
        else
          editor.hideWindow(importWinName)
        end
      end
      im.tooltip('Import road network from disk.')
    end
    im.SameLine()
    im.NextColumn()

    -- 'Export Road Network' button.
    if not isFinalise then
      if isTechLicense and editor.uiIconImageButton(editor.icons.ab_asset_html, vec34, violetB, nil, nil, 'export') then
        export.export()
      end
      im.tooltip('Export road network to disk.')
    end
    im.SameLine()
    im.NextColumn()

    -- Save session button.
    if editor.uiIconImageButton(editor.icons.floppyDisk, vec34, nil, nil, nil, 'saveSession') then
      saveSession()
    end
    im.tooltip('Saves the Road Architect session.')
    im.SameLine()
    im.NextColumn()

    -- Load session button.
    if editor.uiIconImageButton(editor.icons.folder, vec34, dullWhite, nil, nil, 'loadSession') then
      loadSession()
    end
    im.tooltip('Loads a Road Architect session.')
    im.SameLine()
    im.NextColumn()
  end
end

-- Handles the roads list sub-window.
local function handleRoadsListSubWindow(roads, link)
  if isRoadsListWinOpen then
    if editor.beginWindow(roadsListWinName, "Roads###9") then

      im.Separator()

      if im.BeginListBox('', im.ImVec2(200, 180), im.WindowFlags_ChildWindow) then

        im.Columns(4, "roadsListBoxColumns", true)
        im.SetColumnWidth(0, 90)
        im.SetColumnWidth(1, 32)
        im.SetColumnWidth(2, 32)
        im.SetColumnWidth(3, 32)

        local numRoads, rCtr = #roads, 1
        for i = 1, numRoads do
          local road = roads[i]
          if not road.isHidden then
            local flag = i == selectedRoadIdx
            local title = nil
            if road.isLinkRoad then
              title = 'Link [' .. tostring(rCtr) .. ']'
            elseif road.isCivilEngRoads[0] then
              title = 'LSASL [' .. tostring(rCtr) .. ']'
            elseif road.isArc then
              title = 'Arc [' .. tostring(rCtr) .. ']'
            else
              title = 'Spline [' .. tostring(rCtr) .. ']'
            end
            if im.Selectable1(title, flag, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
              selectedRoadIdx = getSelRoadIdx(i)
            end

            im.SameLine()
            im.NextColumn()

            -- 'Remove Selected Road' button.
            if editor.uiIconImageButton(editor.icons.trashBin2, vec22, redB, nil, nil, 'removeRoad') then
              local roadPre = roadMgr.copyRoad(road)
              roadMgr.removeRoad(road.name)
              editor.history:commitAction("EditRoad", { old = roadPre, new = nil }, editRoadUndo, editRoadRedo)
              selectedRoadIdx, selectedNodeIdx = getFirstRoadIdx(), 1
              if isRoadEditWinOpen then
                editor.hideWindow(roadEditWinName)
                isRoadEditWinOpen = false
              end
              if isNodeEditWinOpen then
                editor.hideWindow(nodeEditWinName)
                isNodeEditWinOpen = false
              end
              return
            end
            im.tooltip('Remove this road from scene.')
            im.SameLine()
            im.NextColumn()

            -- 'Go To Selected Road' button.
            if road.nodes and #road.nodes > 1 then
              if editor.uiIconImageButton(editor.icons.cameraFocusTopDown, vec21, greenB, nil, nil, 'goToSelectedRoad') then
                roadMgr.goToRoad(i)
              end
              im.tooltip('Go to this road.')
            else
              im.Dummy(im.ImVec2(1, 1))
            end
            im.SameLine()
            im.NextColumn()

            -- 'Edit Selected Road' button.
            local editRoadCol = blueB
            if isRoadEditWinOpen and i == selectedRoadIdx then editRoadCol = blueD end
            if editor.uiIconImageButton(editor.icons.edit, vec19, editRoadCol, nil, nil, 'editRoad') then
              if i == selectedRoadIdx then
                if isRoadEditWinOpen then                                                             -- If this road is already selected, toggle window open/closed.
                  editor.hideWindow(roadEditWinName)
                else
                  editor.showWindow(roadEditWinName)
                end
                isRoadEditWinOpen = not isRoadEditWinOpen
              else                                                                                    -- If road is not currently selected, open window/keep open, but with this road.
                editor.showWindow(roadEditWinName)
                isRoadEditWinOpen = true
              end
              selectedRoadIdx = getSelRoadIdx(i)
              if isNodeEditWinOpen then
                editor.hideWindow(nodeEditWinName)
                isNodeEditWinOpen = false
              end
            end
            im.tooltip('Edit this road (opens edit window).')
            im.SameLine()
            im.Separator()
            im.NextColumn()
            rCtr = rCtr + 1
          end
        end
        im.EndListBox()
      end

      im.Separator()

      -- 'Domain Of Influence' slider (for terraforming).
      -- [This is only available if there is a terrain block, and the road has no tunnels].
      if terrain then
        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(200)
        im.SliderInt("###49", domainOfInfluence, 1, 500, "Domain Of Influence %d")
        im.PopItemWidth()
        im.PopStyleVar()
        im.tooltip('Set the domain of influence of the terraforming.')
      end

      im.Separator()

      im.Columns(6, "roadsListButtonColumns", false)
      im.SetColumnWidth(0, 33)
      im.SetColumnWidth(1, 33)
      im.SetColumnWidth(2, 33)
      im.SetColumnWidth(3, 33)
      im.SetColumnWidth(2, 33)
      im.SetColumnWidth(3, 33)

      -- 'Add New Spline Road' button.
      if editor.uiIconImageButton(editor.icons.bSpline, vec28, nil, nil, nil, 'addNewSplineRoad') then
        local rIdx = #roadMgr.roads + 1
        local newRoad = roadMgr.createRoadFromTemplate(profileMgr.profiles[selectedProfileIdx].name)
        roadMgr.roads[rIdx] = newRoad
        roadMgr.map[newRoad.name] = rIdx
        selectedRoadIdx = getLastRoadIdx()
        if not isRoadEditWinOpen then
          editor.showWindow(roadEditWinName)
          isRoadEditWinOpen = true
        end
        if isNodeEditWinOpen then
          editor.hideWindow(nodeEditWinName)
          isNodeEditWinOpen = false
        end
      end
      im.tooltip('Add a new spline road.')
      im.SameLine()
      im.NextColumn()

      -- 'Add New Arc Road' button.
      if editor.uiIconImageButton(editor.icons.pathArc, vec28, nil, nil, nil, 'addNewArcRoad') then
        local rIdx = #roadMgr.roads + 1
        local newRoad = roadMgr.createRoadFromTemplate(profileMgr.profiles[selectedProfileIdx].name)
        newRoad.isArc = true
        roadMgr.roads[rIdx] = newRoad
        roadMgr.map[newRoad.name] = rIdx
        selectedRoadIdx = getLastRoadIdx()
        if not isRoadEditWinOpen then
          editor.showWindow(roadEditWinName)
          isRoadEditWinOpen = true
        end
        if isNodeEditWinOpen then
          editor.hideWindow(nodeEditWinName)
          isNodeEditWinOpen = false
        end
      end
      im.tooltip('Add a new arc road.')
      im.SameLine()
      im.NextColumn()

      -- 'Clear/Reset Road Network' button.
      if editor.uiIconImageButton(editor.icons.autorenew, vec28, blueB, nil, nil, 'clearRoadNetwork') then
        roadMgr.clearAllRoads(link)
        if isRoadEditWinOpen then
          editor.hideWindow(roadEditWinName)
          isRoadEditWinOpen = false
        end
        if isNodeEditWinOpen then
          editor.hideWindow(nodeEditWinName)
          isNodeEditWinOpen = false
        end
        selectedRoadIdx, selectedNodeIdx = nil, nil
        isLinkMode = false
        return
      end
      im.tooltip('Reset/clear the road network.')
      im.SameLine()
      im.NextColumn()

      -- 'Terraform Full Road Network' button
      if editor.uiIconImageButton(editor.icons.lineToTerrain, vec28, greenB, nil, nil, 'terraformFullRoadNetwork') then
        terra.terraformTB2Roads(domainOfInfluence[0])
      end
      im.tooltip('Terraform the terrain to the full road network.')
      im.SameLine()
      im.NextColumn()

      -- 'Use Meshes For All Roads' button
      if editor.uiIconImageButton(editor.icons.meshRoad, vec28, redB, nil, nil, 'useAllMeshesButton') then
        roadMgr.setAllMesh()
      end
      im.tooltip('Set all roads to use meshes + decals.')
      im.SameLine()
      im.NextColumn()

      -- 'Use Decals For All Roads' button
      if editor.uiIconImageButton(editor.icons.decalRoad, vec28, redB, nil, nil, 'useAllDecalsButton') then
        roadMgr.setAllDecals()
      end
      im.tooltip('Set all roads to use decals (no meshes).')
      im.SameLine()
      im.NextColumn()

    else
      isRoadsListWinOpen = false -- handle close sub-window.
    end
  end
end

-- Handles the road edit sub-window.
local function handleRoadEditSubWindow(roads)
  if isRoadEditWinOpen then
    local road = roads[selectedRoadIdx]
    if not road then
      isRoadEditWinOpen = false
      editor.hideWindow(roadEditWinName)
      isNodeEditWinOpen = false
      editor.hideWindow(nodeEditWinName)
      return
    end
    local isLinkRoad, isArcRoad, isLinkedTo = road.isLinkRoad, road.isArc, #road.isLinkedToS > 0 or #road.isLinkedToE > 0
    if editor.beginWindow(roadEditWinName, "Road Edit###10") then

      local roadNodes = road.nodes

      -- Node display. [Only display these if the road is in edit mode].
      im.Separator()

      if im.BeginListBox('', im.ImVec2(233, 180), im.WindowFlags_ChildWindow) then

        if not road.isLinkRoad and roadNodes then
          im.Columns(5, "nodeEditBoxColumns", true)
          im.SetColumnWidth(0, 90)
          im.SetColumnWidth(1, 32)
          im.SetColumnWidth(2, 32)
          im.SetColumnWidth(3, 32)
          im.SetColumnWidth(4, 32)

          local numNodes = #roadNodes
          for i = 1, numNodes do
            local flag = i == selectedNodeIdx
            if im.Selectable1('Node [' .. tostring(i) .. ']', flag, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
              selectedNodeIdx = i
            end

            im.SameLine()
            im.NextColumn()

            -- 'Remove Selected Node' button.
            -- [This is only displayed if there are more than two nodes].
            if numNodes > 2 then
              if editor.uiIconImageButton(editor.icons.trashBin2, vec22, redB, nil, nil, 'removeNode') then
                local roadPre = roadMgr.copyRoad(road)
                roadMgr.removeNode(selectedRoadIdx, i)
                selectedNodeIdx = max(1, selectedNodeIdx - 1)
                roadMgr.setDirty(road)
                local roadPost = roadMgr.copyRoad(road)
                editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
                return
              end
              im.tooltip('Remove this node from the road.')
              im.SameLine()
              im.NextColumn()
            else
              im.SameLine()
              im.NextColumn()
            end

            -- 'Add Intermediate Node' button button.
            -- [This is not displayed for the very last node].
            if i < numNodes then
              if editor.uiIconImageButton(editor.icons.nodeLast01, vec21, greenB, nil, nil, 'addIntermediateNode') then
                local roadPre = roadMgr.copyRoad(road)
                roadMgr.addIntermediateNode(selectedRoadIdx, i)
                roadMgr.setDirty(road)
                local roadPost = roadMgr.copyRoad(road)
                editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
              end
              im.tooltip('Add an intermediate node after the selected node (midpoint).')
              im.SameLine()
              im.NextColumn()
            else
              im.SameLine()
              im.NextColumn()
            end

            -- 'Edit Selected Node' button.
            local editNodeCol = blueB
            if isNodeEditWinOpen and i == selectedNodeIdx then editNodeCol = blueD end
            if editor.uiIconImageButton(editor.icons.edit, vec19, editNodeCol, nil, nil, 'editNode') then
              if i == selectedNodeIdx then
                if isNodeEditWinOpen then                                                           -- If this node is already selected, toggle window open/closed.
                  editor.hideWindow(nodeEditWinName)
                else
                  editor.showWindow(nodeEditWinName)
                end
                isNodeEditWinOpen = not isNodeEditWinOpen
              else                                                                                  -- If node not currently selected, open/keep window open, but with this node.
                editor.showWindow(nodeEditWinName)
                isNodeEditWinOpen = true
              end
              selectedNodeIdx = i
            end
            im.tooltip('Edit this node (opens edit window).')

            -- Link/Lock column button.
            -- [Node can be unlocked (if locked) or unlinked (if linked) from here].
            if i == 1 and #road.isLinkedToS > 0 then
              im.SameLine()
              im.NextColumn()
              if editor.uiIconImageButton(editor.icons.attachment, vec19, unlinkCol, nil, nil, 'unlinkRoadStart') then
                roadMgr.unlinkStart(road)
              end
              im.tooltip('Unlink the start of this road, and remove the links.')
            elseif i == #roadNodes and #road.isLinkedToE > 0 then
              im.SameLine()
              im.NextColumn()
              if editor.uiIconImageButton(editor.icons.attachment, vec19, unlinkCol, nil, nil, 'unlinkRoadEnd') then
                roadMgr.unlinkEnd(road)
              end
              im.tooltip('Unlock the end of this road, and remove the links.')
            elseif roadNodes[i].isLocked then
              im.SameLine()
              im.NextColumn()
              if editor.uiIconImageButton(editor.icons.lock, vec19, unlinkCol, nil, nil, 'unlockNode') then
                roadNodes[i].isLocked = false
              end
              im.tooltip('Unlock the highlighted node, so it can be moved.')
            else
              im.NextColumn()
            end
            im.NextColumn()

            im.Separator()
          end
        end
        im.EndListBox()
      end
      im.Separator()

      -- First row of buttons:

      -- 'Profile Select' button
      -- [Only available if the road is not a link road or a road with a link].
      if not isLinkRoad and #road.isLinkedToS < 1 and #road.isLinkedToE < 1 then
        local profileButtonCol = redB
        if isProfilesListWinOpen then profileButtonCol = redD end
        if editor.uiIconImageButton(editor.icons.build, vec28, profileButtonCol, nil, nil, 'selectProfile') then
          if isProfilesListWinOpen then
            local road = roads[selectedRoadIdx]
            profileMgr.updateToNewTemplate(road, profileMgr.profiles[selectedProfileIdx].name)
            roadMgr.updateWAndHToNewProfile(road)
            roadMgr.setDirty(road)
            editor.hideWindow(profilesListWinName)
          else
            editor.showWindow(profilesListWinName)
            if isRoadsListWinOpen then
              editor.hideWindow(roadsListWinName)
              isRoadsListWinOpen = false
            end
            if isNodeEditWinOpen then
              editor.hideWindow(nodeEditWinName)
              isNodeEditWinOpen = false
            end
          end
          isProfilesListWinOpen = not isProfilesListWinOpen
          if isProfileEditWinOpen then
            editor.hideWindow(profileEditWinName)
            isProfileEditWinOpen = false
          end
          if not isProfilesListWinOpen and not isProfileEditWinOpen then
            profileMgr.goToOldView()
            roadMgr.removeHiddenRoads()
            selectedRoadIdx = getSelRoadIdx(selectedRoadIdx)
            roadMgr.setDirty(roads[selectedRoadIdx])
          end
          if isGroupsListWinOpen then
            editor.hideWindow(groupsListWinName)
            isGroupsListWinOpen = false
            groupMgr.goToOldView()
            roadMgr.removeHiddenRoads()
            selectedRoadIdx = getSelRoadIdx(selectedRoadIdx)
            roadMgr.setDirty(roads[selectedRoadIdx])
          end
        end
        im.tooltip('Select a new profile for this road.')
        im.SameLine()
      end

      -- 'Use Civil Engineered Roads' button. Line-spiral-arc-spiral-line at bends, instead of fitted CR-splines.
      -- [Only available if road is not a link road or arc road].
      if not isLinkRoad and not isArcRoad then
        local useCivilEngButtonCol = redB
        local rBtn = editor.icons.bezierPath1
        if road.isCivilEngRoads[0] then useCivilEngButtonCol, rBtn = redD, editor.icons.bezierPath2 end
        if editor.uiIconImageButton(rBtn, vec28, useCivilEngButtonCol, nil, nil, 'UseCivilEngButton') then
          road.isCivilEngRoads = im.BoolPtr(not road.isCivilEngRoads[0])
          roadMgr.setDirty(road)
        end
        im.tooltip('Uses line-spiral-arc-spiral-line sections (instead of splines).')
        im.SameLine()
      end

      -- 'Split Road At Node' button (splits the road into two, with a gap).
      -- [Only show this button if the node is i) not a link road, ii) not an arc road, iii) unlocked, and iv) the selected node is not an start/end point].
      if not isLinkRoad and not isLinkedTo and not isArcRoad and roadNodes[selectedNodeIdx] and not roadNodes[selectedNodeIdx].isLocked and selectedNodeIdx and selectedNodeIdx > 1 and selectedNodeIdx < #roadNodes then
        if editor.uiIconImageButton(editor.icons.content_cut, vec28, redB, nil, nil, 'splitRoadAtNode') then
          if isNodeEditWinOpen then
            editor.hideWindow(nodeEditWinName)
            isNodeEditWinOpen = false
          end
          roadMgr.splitRoad(selectedRoadIdx, selectedNodeIdx, linkMgr.link)
          selectedRoadIdx = getLastRoadIdx()
          return
        end
        im.tooltip('Split road at node, and create a gap (for junctioning).')
        im.SameLine()
      end

      -- 'Flip Road Direction' button.
      -- [Not available for link roads or standard roads which are linked.  There must be at least two nodes].
      if not isLinkRoad and #road.isLinkedToS == 0 and #road.isLinkedToE == 0 and #roadNodes > 1 then
        if editor.uiIconImageButton(editor.icons.autorenew, vec28, redB, nil, nil, 'flipRoadDirection') then
          local roadPre = roadMgr.copyRoad(road)
          roadMgr.flipRoad(selectedRoadIdx)
          local roadPost = roadMgr.copyRoad(road)
          editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
          return
        end
        im.tooltip('Flip the road direction. Changes reference line position on profile')
        im.SameLine()
      end

      -- 'Lock/Unlock Node' button.
      -- [Not available for link roads or first/last nodes on standard roads which are linked to link roads].
      local isStartNodeAndLinked, isEndNodeAndLinked = selectedNodeIdx == 1 and #road.isLinkedToS > 0, selectedNodeIdx == #roadNodes and #road.isLinkedToE > 0
      if not isLinkRoad and not isStartNodeAndLinked and not isEndNodeAndLinked then
        if roadNodes and roadNodes[selectedNodeIdx] and roadNodes[selectedNodeIdx].isLocked then
          if editor.uiIconImageButton(editor.icons.lock_open, vec27, darkLockCol, nil, nil, 'unlockNode') then
            local roadPre = roadMgr.copyRoad(road)
            roadNodes[selectedNodeIdx].isLocked = false
            local roadPost = roadMgr.copyRoad(road)
            editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
          end
          im.tooltip('Unlock the highlighted node, so it can be moved.')
        else
          if editor.uiIconImageButton(editor.icons.lock, vec27, darkLockCol, nil, nil, 'lockNode') then
            local roadPre = roadMgr.copyRoad(road)
            roadNodes[selectedNodeIdx].isLocked = true
            local roadPost = roadMgr.copyRoad(road)
            editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
          end
          im.tooltip('Lock the highlighted node, so that it becomes fixed in space.')
        end
        im.SameLine()
      end

      -- 'Conform Road To Terrain' button.
      -- [Not available for link roads or maps with no terrain block].
      if not isLinkRoad and terrain then
        local isConfTToRButtonCol = redB
        if road.isConformRoadToTerrain[0] then isConfTToRButtonCol = redD end
        if editor.uiIconImageButton(editor.icons.lineToTerrain, vec28, isConfTToRButtonCol, nil, nil, 'conformRoadToTerrainButton') then
          local roadPre = roadMgr.copyRoad(road)
          road.isConformRoadToTerrain = im.BoolPtr(not road.isConformRoadToTerrain[0])
          roadMgr.setDirty(road)
          local roadPost = roadMgr.copyRoad(road)
          editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
        end
        im.tooltip('Conform the road to the terrain.')
        im.SameLine()
      end

      -- 'Allow Tunnels' button.
      -- [Not available for link roads or maps with no terrain block].
      if not isLinkRoad and terrain then
        local isAllowTunnelsButtonCol = redD
        if road.isAllowTunnels[0] then isAllowTunnelsButtonCol = redB end
        if editor.uiIconImageButton(editor.icons.tunnel, vec28, isAllowTunnelsButtonCol, nil, nil, 'AllowTunnelsButton') then
          local roadPre = roadMgr.copyRoad(road)
          road.isAllowTunnels = im.BoolPtr(not road.isAllowTunnels[0])
          roadMgr.setDirty(road)
          local roadPost = roadMgr.copyRoad(road)
          editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
        end
        im.tooltip('Allow tunnels with this road.')
      end

      -- Second row of buttons:

      -- 'Include Mesh' button.
      local includeMeshButtonCol = greenD
      if road.isMesh then includeMeshButtonCol = greenB end
      if editor.uiIconImageButton(editor.icons.meshRoad, vec28, includeMeshButtonCol, nil, nil, 'IncludeMeshButton') then
        local roadPre = roadMgr.copyRoad(road)
        road.isMesh = not road.isMesh
        local roadPost = roadMgr.copyRoad(road)
        editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
      end
      im.tooltip('Generate solid mesh on finalise.')
      im.SameLine()

      -- The 'Road Surface Mesh' toggle button.
      local roadSurfaceColor = greenD
      if road.isDisplayRoadSurface[0] then roadSurfaceColor = greenB end
      if editor.uiIconImageButton(editor.icons.roadFace, vec28, roadSurfaceColor, nil, nil, 'roadSurfaceMeshToggle') then
        local roadPre = roadMgr.copyRoad(road)
        road.isDisplayRoadSurface = im.BoolPtr(not road.isDisplayRoadSurface[0])
        local roadPost = roadMgr.copyRoad(road)
        editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
      end
      im.tooltip('Toggles the road surface mesh.')
      im.SameLine()

      -- The 'Road Outline Mesh' toggle button.
      local roadOutlineColor = greenD
      local rocBtn = editor.icons.grid_off
      if road.isDisplayRoadOutline[0] then roadOutlineColor, rocBtn = greenB, editor.icons.grid_on end
      if editor.uiIconImageButton(rocBtn, vec28, roadOutlineColor, nil, nil, 'roadOutlineMeshToggle') then
        local roadPre = roadMgr.copyRoad(road)
        road.isDisplayRoadOutline = im.BoolPtr(not road.isDisplayRoadOutline[0])
        local roadPost = roadMgr.copyRoad(road)
        editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
      end
      im.tooltip('Toggles the road outline mesh.')
      im.SameLine()

      -- The 'Road Reference Line' toggle button.
      local roadRefLineColor = greenD
      if road.isDisplayRefLine[0] then roadRefLineColor = greenB end
      if editor.uiIconImageButton(editor.icons.roadRefPath, vec28, roadRefLineColor, nil, nil, 'roadRefLineToggle') then
        local roadPre = roadMgr.copyRoad(road)
        road.isDisplayRefLine = im.BoolPtr(not road.isDisplayRefLine[0])
        local roadPost = roadMgr.copyRoad(road)
        editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
      end
      im.tooltip('Toggles the road reference line.')
      im.SameLine()

      -- The 'Node Spheres' and 'Node Numbers toggle buttons.
      -- [Not available for link roads].
      if not isLinkRoad then
        local nodeSpheresColor = greenD
        if road.isDisplayNodeSpheres[0] then nodeSpheresColor = greenB end
        if editor.uiIconImageButton(editor.icons.simobject_particle_emitter_node, vec28, nodeSpheresColor, nil, nil, 'nodeSpheresToggle') then
          local roadPre = roadMgr.copyRoad(road)
          road.isDisplayNodeSpheres = im.BoolPtr(not road.isDisplayNodeSpheres[0])
          local roadPost = roadMgr.copyRoad(road)
          editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
        end
        im.tooltip('Toggles the node spheres.')
        im.SameLine()

        local nodeNumbersColor = greenD
        if road.isDisplayNodeNumbers[0] then nodeNumbersColor = greenB end
        if editor.uiIconImageButton(editor.icons.sphereOnPathNumber, vec28, nodeNumbersColor, nil, nil, 'nodeNumbersToggle') then
          local roadPre = roadMgr.copyRoad(road)
          road.isDisplayNodeNumbers = im.BoolPtr(not road.isDisplayNodeNumbers[0])
          local roadPost = roadMgr.copyRoad(road)
          editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
        end
        im.tooltip('Toggles the node numbering.')
        im.SameLine()
      end

      -- Toggle the 'Lane Info' button.
      local laneInfoColor = greenD
      if road.isDisplayLaneInfo[0] then laneInfoColor = greenB end
      if editor.uiIconImageButton(editor.icons.roadInfo, vec28, laneInfoColor, nil, nil, 'laneInfoToggle') then
        local roadPre = roadMgr.copyRoad(road)
        road.isDisplayLaneInfo = im.BoolPtr(not road.isDisplayLaneInfo[0])
        local roadPost = roadMgr.copyRoad(road)
        editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
      end
      im.tooltip('Toggles the lane info.')
      im.SameLine()

      im.Separator()
      im.Separator()

      -- Third row of buttons:

      -- Toggle the 'Road Reference Line Decal' button.
      local roadRefLineColor = blueD
      if road.isRefLineDecal[0] then roadRefLineColor = blueB end
      if editor.uiIconImageButton(editor.icons.roadRefPathDecal, vec28, roadRefLineColor, nil, nil, 'roadRefLineToggle') then
        local roadPre = roadMgr.copyRoad(road)
        road.isRefLineDecal = im.BoolPtr(not road.isRefLineDecal[0])
        local roadPost = roadMgr.copyRoad(road)
        editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
      end
      im.tooltip('Toggles the road reference line decal.')
      im.SameLine()

      -- Toggle the 'Road Edge Lines Decal' button.
      local roadEdgeLineColor = blueD
      if road.isEdgeLineDecal[0] then roadEdgeLineColor = blueB end
      if editor.uiIconImageButton(editor.icons.roadEdgeLineDecal, vec28, roadEdgeLineColor, nil, nil, 'roadEdgeLinesToggle') then
        local roadPre = roadMgr.copyRoad(road)
        road.isEdgeLineDecal = im.BoolPtr(not road.isEdgeLineDecal[0])
        local roadPost = roadMgr.copyRoad(road)
        editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
      end
      im.tooltip('Toggles the road edge line decals.')
      im.SameLine()

      -- Toggle the 'Road Lane Divisions Decal' button.
      local roadLaneDivColor = blueD
      if road.isLaneDivsDecal[0] then roadLaneDivColor = blueB end
      if editor.uiIconImageButton(editor.icons.roadDividerLinesDecal, vec28, roadLaneDivColor, nil, nil, 'roadLaneDivsToggle') then
        local roadPre = roadMgr.copyRoad(road)
        road.isLaneDivsDecal = im.BoolPtr(not road.isLaneDivsDecal[0])
        local roadPost = roadMgr.copyRoad(road)
        editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
      end
      im.tooltip('Toggles the lane division decals.')
      im.SameLine()

      -- Toggle the 'Road Start Line Decal' button.
      local roadStartLineColor = blueD
      if road.isStartLineDecal[0] then roadStartLineColor = blueB end
      if editor.uiIconImageButton(editor.icons.roadStartLineDecal, vec28, roadStartLineColor, nil, nil, 'roadStartLineToggle') then
        local roadPre = roadMgr.copyRoad(road)
        road.isStartLineDecal = im.BoolPtr(not road.isStartLineDecal[0])
        local roadPost = roadMgr.copyRoad(road)
        editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
      end
      im.tooltip('Toggles the road start line decal.')
      im.SameLine()

      -- Toggle the 'Road End Line Decal' button.
      local roadEndLineColor = blueD
      if road.isEndLineDecal[0] then roadEndLineColor = blueB end
      if editor.uiIconImageButton(editor.icons.roadEndLineDecal, vec28, roadEndLineColor, nil, nil, 'roadEndLineToggle') then
        local roadPre = roadMgr.copyRoad(road)
        road.isEndLineDecal = im.BoolPtr(not road.isEndLineDecal[0])
        local roadPost = roadMgr.copyRoad(road)
        editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
      end
      im.tooltip('Toggles the road end line decal.')

      im.Separator()

      -- Longitudinal Target Resolution slider.
      -- [Not available for arc roads].
      if not isArcRoad then
        local oldTLR = road.targetLonRes[0]
        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(233)
        im.SliderFloat("###1", road.targetLonRes, 1.5, 20.0, "Line Resolution = %.3f")
        im.PopItemWidth()
        im.PopStyleVar()
        im.tooltip('The resolution of splines and linear road sections.')
        im.Separator()
        road.targetLonRes = im.FloatPtr(min(20.0, max(1.5, road.targetLonRes[0])))
        if oldTLR ~= road.targetLonRes[0] then
          roadMgr.setDirty(road)
        end
      end

      -- Sliders/Checkboxes Row.
      -- [Not available for link roads].
      if not road.isLinkRoad then

        -- Circular Arc Target Resolution slider.
        -- [Only available if the road is a civil engineering style spline or an arc road].
        if road.isCivilEngRoads[0] or isArcRoad then
          local oldTAR = road.targetArcRes[0]
          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.PushItemWidth(233)
          im.SliderFloat("###2", road.targetArcRes, 0.5, 10.0, "Arc Resolution = %.3f")
          im.PopItemWidth()
          im.PopStyleVar()
          im.tooltip('The resolution of arc road sections.')
          im.Separator()
          road.targetArcRes = im.FloatPtr(min(10.0, max(0.5, road.targetArcRes[0])))
          if oldTAR ~= road.targetArcRes[0] then
            roadMgr.setDirty(road)
          end
        end

        -- 'Use Rigid Translation' button.
        local useRigidTranButtonCol = redD
        if road.isRigidTranslation[0] then useRigidTranButtonCol = redB end
        if editor.uiIconImageButton(editor.icons.transform, vec22, useRigidTranButtonCol, nil, nil, 'UseRigidTranslationButton') then
          local roadPre = roadMgr.copyRoad(road)
          road.isRigidTranslation = im.BoolPtr(not road.isRigidTranslation[0])
          local roadPost = roadMgr.copyRoad(road)
          editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
        end
        im.tooltip('Switch on/off rigid translation mode for this road.')
        im.SameLine()

        -- Force Field slider (for non-rigid translations).
        if not road.isRigidTranslation[0] then
          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.PushItemWidth(205)
          im.SliderFloat("###3", road.forceField, 0.1, 205.0, "Movement Field = %.3f")
          im.PopItemWidth()
          im.PopStyleVar()
          im.tooltip('Amount of nearby elastic effect when dragging single nodes.')
        end
        im.Separator()

        -- 'Conform Terrain To Road' button and 'Domain Of Influence' slider (for terraforming).
        -- [This is only available if there is a terrain block, and the road has no tunnels].
        if terrain and not road.isConformRoadToTerrain[0] then
          if editor.uiIconImageButton(editor.icons.forest_snap_terrain, vec22, redB, nil, nil, 'ConformTerrainToRoadButton') then
            terra.conformTerrainToRoad(selectedRoadIdx, domainOfInfluence[0])
            roadMgr.setDirty(road)
          end
          im.tooltip('Conform the terrain to this road.')
          im.SameLine()

          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.PushItemWidth(205)
          im.SliderInt("###49", domainOfInfluence, 1, 500, "Domain Of Influence %d")
          im.PopItemWidth()
          im.PopStyleVar()
          im.tooltip('Set the domain of influence of the terraforming.')
        end

        -- Road centerline decal further options.
        if road.isRefLineDecal[0] then
          im.Separator()
          im.TextColored(greenB, 'Centerline Decal Parameters:')

          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.PushItemWidth(233)
          im.SliderFloat("###58", road.centerlineWidth, 0.01, 0.3, "Decal Width = %.2f")
          im.PopItemWidth()
          im.PopStyleVar()
          im.tooltip('Set the road centerline decal width, in meters.')
        end

        -- Road edge decal further options.
        if road.isEdgeLineDecal[0] then
          im.Separator()
          im.TextColored(greenB, 'Road Edge Decal Parameters:')

          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.PushItemWidth(233)
          im.SliderFloat("###59", road.edgeDecalWidth, 0.01, 0.3, "Decal Width = %.2f")
          im.PopItemWidth()
          im.PopStyleVar()
          im.tooltip('Set the road edge decal widths, in meters.')

          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.PushItemWidth(233)
          im.SliderFloat("###60", road.edgeDecalDist, -2.0, 2.0, "Decal Lateral Offset = %.2f")
          im.PopItemWidth()
          im.PopStyleVar()
          im.tooltip('Set the road edge decal lateral offset, in meters.')
        end

        -- Road lane division marking decals - further options.
        if road.isLaneDivsDecal[0] then
          im.Separator()
          im.TextColored(greenB, 'Lane Division Decal Parameters:')

          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.PushItemWidth(233)
          im.SliderFloat("###57", road.laneMarkingWidth, 0.01, 0.3, "Decal Width = %.2f")
          im.PopItemWidth()
          im.PopStyleVar()
          im.tooltip('Set the lane division decal widths, in meters.')
        end

        -- Road start/end line marking decals - further options.
        if road.isStartLineDecal[0] or road.isEndLineDecal[0] then
          im.Separator()
          im.TextColored(greenB, 'Start/End Line Decal Parameters:')

          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.PushItemWidth(233)
          im.SliderFloat("###56", road.jctLineWidth, 0.1, 4.0, "Decal Width = %.2f")
          im.PopItemWidth()
          im.PopStyleVar()
          im.tooltip('Set the start/end crossing decal widths, in meters.')

          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.PushItemWidth(233)
          im.SliderFloat("###55", road.jctLineOffset, -10.0, 10.0, "Decal Offset = %.2f")
          im.PopItemWidth()
          im.PopStyleVar()
          im.tooltip('Set the start/end line crossing decal offset, in meters.')
        end

        -- Lamp posts - further options.
        im.Separator()
        im.TextColored(greenB, 'Lamp Post Parameters:')

        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(233)
        im.SliderFloat("###61", road.lampPostLonSpacing, 1.0, 100.0, "Lamp Spacing = %.2f")
        im.PopItemWidth()
        im.PopStyleVar()
        im.tooltip('Set the longitudinal spacing between lamp posts.')

        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(233)
        im.SliderFloat("###64", road.lampJitter, 0.0, 0.2, "Jitter = %.2f")
        im.PopItemWidth()
        im.PopStyleVar()
        im.tooltip('Set the amount of random jitter of the lamp posts.')

        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(233)
        im.SliderFloat("###65", road.lampPostLonOffset, 0.0, 100.0, "Longitudinal Offset = %.2f")
        im.PopItemWidth()
        im.PopStyleVar()
        im.tooltip('Set the starting longitudinal offset between the first lamp post and the road start.')

        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(233)
        im.SliderFloat("###66", road.lampPostVertOffset, -10.0, 10.0, "Vertical Offset = %.2f")
        im.PopItemWidth()
        im.PopStyleVar()
        im.tooltip('Set the vertical offset of the lamp posts.')

        -- Crash Barrier - further options.
        im.Separator()
        im.TextColored(greenB, 'Crash Barrier Parameters:')

        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(233)
        im.SliderFloat("###74", road.crashPostLonOffset, 0.0, 100.0, "Longitudinal Offset = %.2f")
        im.PopItemWidth()
        im.PopStyleVar()
        im.tooltip('Set the starting longitudinal offset between the barrier start and the road start.')

        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(233)
        im.SliderFloat("###75", road.crashVertOffset, -10.0, 10.0, "Vertical Offset = %.2f")
        im.PopItemWidth()
        im.PopStyleVar()
        im.tooltip('Set the vertical offset of the barriers.')

        im.Checkbox("Use Double Plates", road.useDoublePlate)
        im.tooltip('Use two stacked frontal plates on the crash barriers, instead of just one.')

        -- Concrete Barriers - further options.
        im.Separator()
        im.TextColored(greenB, 'Concrete Barrier Parameters:')

        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(233)
        im.SliderFloat("###84", road.barrierLonOffset, 0.0, 100.0, "Longitudinal Offset = %.2f")
        im.PopItemWidth()
        im.PopStyleVar()
        im.tooltip('Set the starting longitudinal offset between the concrete barrier start and the road start.')

        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(233)
        im.SliderFloat("###85", road.barrierVertOffset, -10.0, 10.0, "Vertical Offset = %.2f")
        im.PopItemWidth()
        im.PopStyleVar()
        im.tooltip('Set the vertical offset of the concrete barriers.')

        -- Mesh Fences - further options.
        im.Separator()
        im.TextColored(greenB, 'Mesh Fence Parameters:')

        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(233)
        im.SliderFloat("###87", road.fenceLonOffset, 0.0, 100.0, "Longitudinal Offset = %.2f")
        im.PopItemWidth()
        im.PopStyleVar()
        im.tooltip('Set the starting longitudinal offset between the fence start and the road start.')

        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(233)
        im.SliderFloat("###88", road.fenceVertOffset, -10.0, 10.0, "Vertical Offset = %.2f")
        im.PopItemWidth()
        im.PopStyleVar()
        im.tooltip('Set the vertical offset of the mesh fences.')

        -- Bollards - further options.
        im.Separator()
        im.TextColored(greenB, 'Bollard Parameters:')

        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(233)
        im.SliderFloat("###91", road.bollardLonSpacing, 1.0, 100.0, "Bollard Spacing = %.2f")
        im.PopItemWidth()
        im.PopStyleVar()
        im.tooltip('Set the longitudinal spacing between bollards.')

        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(233)
        im.SliderFloat("###92", road.bollardJitter, 0.0, 0.2, "Jitter = %.2f")
        im.PopItemWidth()
        im.PopStyleVar()
        im.tooltip('Set the amount of random jitter of the bollards.')

        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(233)
        im.SliderFloat("###93", road.bollardLonOffset, 0.0, 100.0, "Longitudinal Offset = %.2f")
        im.PopItemWidth()
        im.PopStyleVar()
        im.tooltip('Set the starting longitudinal offset between the first bollard and the road start.')

        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(233)
        im.SliderFloat("###94", road.bollardVertOffset, -10.0, 10.0, "Vertical Offset = %.2f")
        im.PopItemWidth()
        im.PopStyleVar()
        im.tooltip('Set the vertical offset of the bollards.')

        -- Tunnels - further options.
        if #road.tunnels > 0 then
          im.Separator()
          im.TextColored(greenB, 'Tunnel Parameters:')

          -- Wall Thickness.
          im.PushItemWidth(130)
          if im.InputFloat("Wall Depth", road.thickness, 0.1, 0.0) then
            roadMgr.setDirty(road)
          end
          im.tooltip('Sets the thickness of the tunnel walls.')
          im.PopItemWidth()
          road.thickness = im.FloatPtr(max(0.1, min(20.0, road.thickness[0])))

          -- Radius offset.
          im.PushItemWidth(130)
          if im.InputFloat("R Offset", road.radOffset, 0.1, 0.0) then
            roadMgr.setDirty(road)
          end
          im.tooltip('Sets the tunnel radius offset.')
          im.PopItemWidth()
          road.radOffset = im.FloatPtr(max(-10.0, min(10.0, road.radOffset[0])))

          -- Wall Thickness.
          im.PushItemWidth(130)
          if im.InputFloat("Z Offset", road.zOffsetFromRoad, 0.1, 0.0) then
            roadMgr.setDirty(road)
          end
          im.tooltip('Sets the vertical offset of the road inside the tunnel.')
          im.PopItemWidth()
          road.zOffsetFromRoad = im.FloatPtr(max(-30.0, min(30.0, road.zOffsetFromRoad[0])))

          -- Start protrusion amount.
          im.PushItemWidth(130)
          if im.InputFloat("Extend S", road.protrudeS, 0.1, 0.0) then
            roadMgr.setDirty(road)
          end
          im.tooltip('Sets the amount of extension at the start of the tunnel.')
          im.PopItemWidth()
          road.protrudeS = im.FloatPtr(max(0.0, min(30.0, road.protrudeS[0])))

          -- End protrusion amount.
          im.PushItemWidth(130)
          if im.InputFloat("Extend E", road.protrudeE, 0.1, 0.0) then
            roadMgr.setDirty(road)
          end
          im.tooltip('Sets the amount of extension at the end of the tunnel.')
          im.PopItemWidth()
          road.protrudeE = im.FloatPtr(max(0.0, min(30.0, road.protrudeE[0])))

          -- Start position on road (longitudinal div point).
          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.PushItemWidth(233)
          if im.SliderInt("###42", road.extraS, 0, 15, "Start Pos %d") then
            roadMgr.setDirty(road)
          end
          im.PopItemWidth()
          im.PopStyleVar()
          im.tooltip('Sets the general tunnel start position, on the road.')

          -- End position on road (longitudinal div point).
          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.PushItemWidth(233)
          if im.SliderInt("###43", road.extraE, 0, 15, "End Pos %d") then
            roadMgr.setDirty(road)
          end
          im.PopItemWidth()
          im.PopStyleVar()
          im.tooltip('Sets the general tunnel end position, on the road.')

          -- Tunnel mesh granularity.
          im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
          im.PushItemWidth(233)
          if im.SliderInt("###41", road.radGran, 6, 50, "Granularity %d") then
            roadMgr.setDirty(road)
          end
          im.PopItemWidth()
          im.PopStyleVar()
          im.tooltip('Tunnel mesh granularity.')
        end
        im.Separator()
      end
    else
      isRoadEditWinOpen = false -- handle close sub-window.
      if isNodeEditWinOpen then
        editor.hideWindow(nodeEditWinName)
        isNodeEditWinOpen = false
      end
    end
  end
end

-- Handles the node edit sub-window.
local function handleNodeEditSubWindow(roads)
  if isNodeEditWinOpen then
    if editor.beginWindow(nodeEditWinName, "Node: [" .. tostring(selectedNodeIdx) .. "]###11") then
      local road = roadMgr.roads[selectedRoadIdx]
      if road then
        local nodes = road.nodes
        local node = nodes[selectedNodeIdx]
        if node then

          local isStartLinkedAndStart = selectedNodeIdx == 1 and #road.isLinkedToS > 0
          local isEndLinkedAndEnd = selectedNodeIdx == #nodes and #road.isLinkedToE > 0
          local widths = node.widths

          -- Left lanes.
          im.Separator()
          im.Text('Left Lanes:')
          if im.BeginListBox('###1', im.ImVec2(700, 100), im.WindowFlags_ChildWindow) then
            if not isStartLinkedAndStart and not isEndLinkedAndEnd then
              im.Columns(5, "roadsListBoxColumns", true)
              im.SetColumnWidth(0, 50)
              im.SetColumnWidth(1, 100)
              im.SetColumnWidth(2, 180)
              im.SetColumnWidth(3, 180)
              im.SetColumnWidth(4, 180)

              local ctr = 30
              for i = -20, -1 do
                if widths[i] then
                  local flag = i == selectedLaneIdx
                  if im.Selectable1('[' .. tostring(i) .. ']', flag, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
                    selectedLaneIdx = i
                  end

                  im.SameLine()
                  im.NextColumn()

                  im.Text(road.profile[i].type)

                  im.SameLine()
                  im.NextColumn()

                  -- 'Set Node Width' input box.
                  local wOld = node.widths[i][0]
                  im.PushItemWidth(130)
                  im.InputFloat("W###" .. tostring(ctr) .. "", node.widths[i], 0.1, 0.0)
                  im.tooltip('Sets the width of this lane.')
                  im.PopItemWidth()
                  node.widths[i] = im.FloatPtr(max(0.0, min(10.0, node.widths[i][0])))
                  if wOld ~= node.widths[i][0] then
                    roadMgr.setDirty(roads[selectedRoadIdx])
                  end

                  im.SameLine()
                  im.NextColumn()

                  -- 'Set Node Left Relative Height' input box.
                  local hLOld = node.heightsL[i][0]
                  im.PushItemWidth(130)
                  im.InputFloat("H(L)###" .. tostring(ctr + 1) .. "", node.heightsL[i], 0.1, 0.0)
                  im.tooltip('Sets the relative height of the left edge of this lane.')
                  im.PopItemWidth()
                  node.heightsL[i] = im.FloatPtr(max(0.0, min(3.0, node.heightsL[i][0])))
                  if hLOld ~= node.heightsL[i][0] then
                    roadMgr.setDirty(roads[selectedRoadIdx])
                  end

                  im.SameLine()
                  im.NextColumn()

                  -- Set Node Right Relative Height' input box.
                  local hROld = node.heightsR[i][0]
                  im.PushItemWidth(130)
                  im.InputFloat("H(R)###" .. tostring(ctr + 2) .. "", node.heightsR[i], 0.1, 0.0)
                  im.tooltip('Sets the relative height of the right edge of this lane.')
                  im.PopItemWidth()
                  node.heightsR[i] = im.FloatPtr(max(0.0, min(3.0, node.heightsR[i][0])))
                  if hROld ~= node.heightsR[i][0] then
                    roadMgr.setDirty(roads[selectedRoadIdx])
                  end

                  im.SameLine()
                  im.Separator()
                  im.NextColumn()

                  ctr = ctr + 3
                end
              end
            end
            im.EndListBox()
          end

          -- Right lane widths.
          im.Separator()
          im.Text('Right Lanes:')
          if im.BeginListBox('###2', im.ImVec2(700, 100), im.WindowFlags_ChildWindow) then
            if not isStartLinkedAndStart and not isEndLinkedAndEnd then
              im.Columns(5, "roadsListBoxColumns", true)
              im.SetColumnWidth(0, 50)
              im.SetColumnWidth(1, 100)
              im.SetColumnWidth(2, 180)
              im.SetColumnWidth(3, 180)
              im.SetColumnWidth(4, 180)

              local ctr = 40
              for i = 1, 20 do
                if widths[i] then
                  local flag = i == selectedLaneIdx
                  if im.Selectable1('[' .. tostring(i) .. ']', flag, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
                    selectedLaneIdx = i
                  end

                  im.SameLine()
                  im.NextColumn()

                  im.Text(road.profile[i].type)

                  im.SameLine()
                  im.NextColumn()

                  local wOld = node.widths[i][0]
                  im.PushItemWidth(130)
                  im.InputFloat("W###" .. tostring(ctr) .. "", node.widths[i], 0.1, 0.0)
                  im.tooltip('Sets the width of this lane.')
                  im.PopItemWidth()
                  node.widths[i] = im.FloatPtr(max(0.0, min(10.0, node.widths[i][0])))
                  if wOld ~= node.widths[i][0] then
                    roadMgr.setDirty(roads[selectedRoadIdx])
                  end

                  im.SameLine()
                  im.NextColumn()

                  -- 'Set Node Left Relative Height' input box.
                  local hLOld = node.heightsL[i][0]
                  im.PushItemWidth(130)
                  im.InputFloat("H(L)###" .. tostring(ctr + 1) .. "", node.heightsL[i], 0.1, 0.0)
                  im.tooltip('Sets the relative height of the left edge of this lane.')
                  im.PopItemWidth()
                  node.heightsL[i] = im.FloatPtr(max(0.0, min(3.0, node.heightsL[i][0])))
                  if hLOld ~= node.heightsL[i][0] then
                    roadMgr.setDirty(roads[selectedRoadIdx])
                  end

                  im.SameLine()
                  im.NextColumn()

                  -- Set Node Right Relative Height' input box.
                  local hROld = node.heightsR[i][0]
                  im.PushItemWidth(130)
                  im.InputFloat("H(R)###" .. tostring(ctr + 2) .. "", node.heightsR[i], 0.1, 0.0)
                  im.tooltip('Sets the relative height of the right edge of this lane.')
                  im.PopItemWidth()
                  node.heightsR[i] = im.FloatPtr(max(0.0, min(3.0, node.heightsR[i][0])))
                  if hROld ~= node.heightsR[i][0] then
                    roadMgr.setDirty(roads[selectedRoadIdx])
                  end

                  im.SameLine()
                  im.Separator()
                  im.NextColumn()

                  ctr = ctr + 3
                end
              end
            end
            im.EndListBox()
          end

          im.Columns(3, "roadsListSliderColumns", true)
          im.SetColumnWidth(0, 200)
          im.SetColumnWidth(1, 200)
          im.SetColumnWidth(2, 200)

          -- The relative height and lateral rotation controls only appear if the road is not set to conform to the terrain.
          -- [This is not available for arc middle nodes].
          if not road.isConformRoadToTerrain[0] and not (road.isArc and selectedNodeIdx == 2) then

            -- The 'Relative Height' input box.
            local oldHeight = node.p.z
            local nodeHeight = im.FloatPtr(oldHeight)
            im.PushItemWidth(130)
            if im.InputFloat("Height", nodeHeight, 0.1, 0.0) then
              local roadPre = roadMgr.copyRoad(road)
              roadMgr.adjustHeight(nodeHeight[0], oldHeight, selectedNodeIdx, selectedRoadIdx)
              nodeHeight = im.FloatPtr(max(0, min(2000, nodeHeight[0])))
              local roadPost = roadMgr.copyRoad(road)
              editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
            end
            im.tooltip('The elevation at the node, in meters.')
            im.PopItemWidth()
            im.SameLine()
            im.NextColumn()

            -- The 'Lateral Rotation' input box.
            local oldRot = node.rot[0]
            im.PushItemWidth(130)
            im.InputFloat("Rotation", node.rot, 0.25, 0.0)
            im.tooltip('The lateral rotation at this node, in degrees.')
            im.PopItemWidth()
            if oldRot ~= node.rot[0] then
              local roadPre = roadMgr.copyRoad(road)
              roadMgr.adjustLateralRotation(node.rot[0], oldRot, selectedNodeIdx, selectedRoadIdx)
              local roadPost = roadMgr.copyRoad(road)
              editor.history:commitAction("EditRoad", { old = roadPre, new = roadPost }, editRoadUndo, editRoadRedo)
            end
            im.SameLine()
            im.NextColumn()
          else
            im.SameLine()
            im.NextColumn()
            im.SameLine()
            im.NextColumn()
          end

          -- The 'Civil Engineering Node Incircle Radius' slider.
          if road.isCivilEngRoads[0] then
            local oldICR = node.incircleRad[0]
            im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
            im.PushItemWidth(133)
            im.SliderFloat("Arc Rad", node.incircleRad, 1.0, 2.0, "Radius = %.3f")
            im.tooltip('The radius of the arc at this node.')
            im.PopItemWidth()
            im.PopStyleVar()
            node.incircleRad = im.FloatPtr(min(2.0, max(1.0, node.incircleRad[0])))
            if oldICR ~= node.incircleRad[0] then
              roadMgr.setDirty(road)
            end
          end
          im.SameLine()
          im.NextColumn()
        else
          isNodeEditWinOpen = false                                                                 -- Node no longer exists, so close the node edit window.
          editor.hideWindow(nodeEditWinName)
        end
      end
    else
      isNodeEditWinOpen = false -- handle close sub-window.
    end
  end
end

-- Handles the profiles list sub-window.
local function handleProfilesListSubWindow(roads)
  if isProfilesListWinOpen then
    if editor.beginWindow(profilesListWinName, "Lateral Road Profiles###12") then

      im.Separator()

      if im.BeginListBox('', im.ImVec2(220, 180), im.WindowFlags_ChildWindow) then

        im.Columns(2, "profilesListBoxColumns", true)
        im.SetColumnWidth(0, 150)
        im.SetColumnWidth(1, 32)

        local numProfiles = #profileMgr.profiles
        for i = 1, numProfiles do
          local profile = profileMgr.profiles[i]
          if not profile.isHidden then
            local flag = i == selectedProfileIdx
            if im.Selectable1(profile.name, flag, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
              selectedProfileIdx = i
              updateRoadToNewProfile()
              roadMgr.setAuditionProfileDirty()
            end

            im.SameLine()
            im.NextColumn()

            -- 'Edit Selected Profile' button.
            local editProfileCol = blueB
            if isProfileEditWinOpen and i == selectedProfileIdx then editProfileCol = blueD end
            if editor.uiIconImageButton(editor.icons.edit, vec19, editProfileCol, nil, nil, 'editProfile') then
              if i == selectedProfileIdx then
                if isProfileEditWinOpen then                                                        -- If this profile is already selected, toggle window open/closed.
                  editor.hideWindow(profileEditWinName)
                else
                  editor.showWindow(profileEditWinName)
                end
                isProfileEditWinOpen = not isProfileEditWinOpen
              else                                                                                  -- If profile not currently selected, open/keep window open, but with this profile.
                editor.showWindow(profileEditWinName)
                isProfileEditWinOpen = true
              end
              if not isProfilesListWinOpen and not isProfileEditWinOpen then
                profileMgr.goToOldView()
                roadMgr.removeHiddenRoads()
              end
              if isGroupsListWinOpen then
                editor.hideWindow(groupsListWinName)
                isGroupsListWinOpen = false
                groupMgr.goToOldView()
                roadMgr.removeHiddenRoads()
              end
              selectedProfileIdx = i
              updateRoadToNewProfile()
            end
            im.tooltip('Edit this lateral road profile (opens edit window).')
            im.SameLine()
            im.Separator()
            im.NextColumn()
          end
        end
        im.EndListBox()
      end

      im.Columns(4, "profileListColumns", true)
      im.SetColumnWidth(0, 32)
      im.SetColumnWidth(1, 40)
      im.SetColumnWidth(2, 80)
      im.SetColumnWidth(3, 80)

      -- 'Save Lateral Road Profiles' button.
      if editor.uiIconImageButton(editor.icons.floppyDisk, vec28, nil, nil, nil, 'saveProfiles') then
        profileMgr.save()
      end
      im.tooltip('Save profile collection to disk.')
      im.SameLine()
      im.NextColumn()

      -- 'Load Lateral Road Profiles' button.
      if editor.uiIconImageButton(editor.icons.folder, vec28, dullWhite, nil, nil, 'loadProfiles') then
        profileMgr.load()
      end
      im.tooltip('Load profile collection from disk.')
      im.SameLine()
      im.NextColumn()

      local oldVal = roadMgr.isPOline[0]
      im.Checkbox("Outline", roadMgr.isPOline)
      im.tooltip('Displays a mesh outline around the road.')
      im.SameLine()
      im.NextColumn()
      if oldVal ~= roadMgr.isPOline[0] then
        roadMgr.setAuditionProfileDirty()
      end

      oldVal = roadMgr.isPLane[0]
      im.Checkbox("Lanes", roadMgr.isPLane)
      im.tooltip('Displays lane directions/markings.')
      im.SameLine()
      im.NextColumn()
      if oldVal ~= roadMgr.isPLane[0] then
        roadMgr.setAuditionProfileDirty()
      end

    else
      isProfilesListWinOpen = false -- handle close sub-window.
      if isProfileEditWinOpen then
        editor.hideWindow(profileEditWinName)
        isProfileEditWinOpen = false
      end
      profileMgr.goToOldView()
      roadMgr.removeHiddenRoads()
      selectedRoadIdx = getSelRoadIdx(selectedRoadIdx)
      roadMgr.setDirty(roads[selectedRoadIdx])
    end
  end
end

-- Handles the profile edit sub-window.
local function handleProfileEditSubWindow(roads)
  if isProfileEditWinOpen then
    if editor.beginWindow(profileEditWinName, "Profile Editor###13") then

      local profile = profileMgr.profiles[selectedProfileIdx]
      local wCtr = 1

      -- Left lanes.
      im.Separator()
      im.Text('Left Lanes:')
      if im.BeginListBox('###1', im.ImVec2(840, 200), im.WindowFlags_ChildWindow) then

        im.Columns(10, "profileEditBoxColumnsLeft", true)
        im.SetColumnWidth(0, 40)
        im.SetColumnWidth(1, 32)
        im.SetColumnWidth(2, 32)
        im.SetColumnWidth(3, 32)
        im.SetColumnWidth(4, 32)
        im.SetColumnWidth(5, 85)
        im.SetColumnWidth(6, 32)
        im.SetColumnWidth(7, 180)
        im.SetColumnWidth(8, 180)
        im.SetColumnWidth(9, 180)

        -- Iterate over all possible left lanes, and display them in order from outermost to innermost.
        for i = -20, -1 do
          local lane = profile[i]
          if lane then
            local flag = i == selectedLaneIdx
            if im.Selectable1(tostring(i), flag, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
              selectedLaneIdx = i
            end

            im.SameLine()
            im.NextColumn()

            -- 'Remove Selected Lane' button.
            if editor.uiIconImageButton(editor.icons.trashBin2, vec22, redB, nil, nil, 'removeSelectedLaneLeft') then
              profileMgr.removeLane(selectedProfileIdx, i, 'left')
              updateRoadToNewProfile()
              roadMgr.setAuditionProfileDirty()
            end
            im.tooltip('Remove this lane from profile.')
            im.SameLine()
            im.NextColumn()

            -- 'Add New Lane Above' button.
            if editor.uiIconImageButton(editor.icons.vertical_align_top, vec22, greenB, nil, nil, 'addLaneAboveLeft') then
              profileMgr.addLane(selectedProfileIdx, i, 'left', 'above')
              updateRoadToNewProfile()
              roadMgr.setAuditionProfileDirty()
            end
            im.tooltip('Add a new lane above this lane.')
            im.SameLine()
            im.NextColumn()

            -- 'Add New Lane Below' button.
            if editor.uiIconImageButton(editor.icons.vertical_align_bottom, vec22, greenB, nil, nil, 'addLaneBelowLeft') then
              profileMgr.addLane(selectedProfileIdx, i, 'left', 'below')
              updateRoadToNewProfile()
              roadMgr.setAuditionProfileDirty()
            end
            im.tooltip('Add a new lane below this lane.')
            im.SameLine()
            im.NextColumn()

            -- 'Select New Lane Type' button.
            if editor.uiIconImageButton(editor.icons.fg_lt, vec22, blueB, nil, nil, 'selectLaneTypeLeft1Button') then
              lane.type = profileMgr.cycleLaneTypeBack(lane.type)
              updateRoadToNewProfile()
              roadMgr.setAuditionProfileDirty()
            end
            im.tooltip('Cycle back through available lane types.')
            im.SameLine()
            im.NextColumn()

            -- Display the current type for this lane.
            im.Text(lane.type)
            im.SameLine()
            im.NextColumn()

            -- 'Select New Lane Type' button.
            if editor.uiIconImageButton(editor.icons.fg_gt, vec22, blueB, nil, nil, 'selectLaneTypeLeft2Button') then
              lane.type = profileMgr.cycleLaneType(lane.type)
              updateRoadToNewProfile()
              roadMgr.setAuditionProfileDirty()
            end
            im.tooltip('Cycle forward through available lane types.')
            im.SameLine()
            im.NextColumn()

            -- Width input box.
            local oldWidth = lane.width[0]
            im.PushItemWidth(130)
            im.InputFloat("W###" .. tostring(wCtr), lane.width, 0.1, 0.0)
            wCtr = wCtr + 1
            im.tooltip('The lane width.')
            im.PopItemWidth()
            im.SameLine()
            im.NextColumn()
            lane.width = im.FloatPtr(max(1e-3, min(10.0, lane.width[0])))
            if lane.width[0] ~= oldWidth then
              updateRoadToNewProfile()
              roadMgr.setAuditionProfileDirty()
            end

            -- Relative height (left) input box.
            local oldHeightL = lane.heightL[0]
            im.PushItemWidth(130)
            im.InputFloat("H(L)###" .. tostring(wCtr), lane.heightL, 0.01, 0.0)
            wCtr = wCtr + 1
            im.tooltip('The relative height of the lane left edge.')
            im.PopItemWidth()
            im.SameLine()
            im.NextColumn()
            lane.heightL = im.FloatPtr(max(0.4, min(3.0, lane.heightL[0])))
            if lane.heightL[0] ~= oldHeightL then
              updateRoadToNewProfile()
              roadMgr.setAuditionProfileDirty()
            end

            -- Relative height (right) input box.
            local oldHeightR = lane.heightR[0]
            im.PushItemWidth(130)
            im.InputFloat("H(R)###" .. tostring(wCtr), lane.heightR, 0.01, 0.0)
            wCtr = wCtr + 1
            im.tooltip('The relative height of the lane right edge.')
            im.PopItemWidth()
            im.SameLine()
            im.Separator()
            im.NextColumn()
            lane.heightR = im.FloatPtr(max(0.4, min(3.0, lane.heightR[0])))
            if lane.heightR[0] ~= oldHeightR then
              updateRoadToNewProfile()
              roadMgr.setAuditionProfileDirty()
            end
          end
        end
        im.EndListBox()
      end

      -- Right lanes.
      im.Separator()
      im.Text('Right Lanes:')
      if im.BeginListBox('###2', im.ImVec2(840, 200), im.WindowFlags_ChildWindow) then

        im.Columns(10, "profileEditBoxColumnsRight", true)
        im.SetColumnWidth(0, 40)
        im.SetColumnWidth(1, 32)
        im.SetColumnWidth(2, 32)
        im.SetColumnWidth(3, 32)
        im.SetColumnWidth(4, 32)
        im.SetColumnWidth(5, 85)
        im.SetColumnWidth(6, 32)
        im.SetColumnWidth(7, 180)
        im.SetColumnWidth(8, 180)
        im.SetColumnWidth(9, 180)

        -- Iterate over all possible right lanes, and display them in order from innermost to outermost.
        for i = 1, 10 do
          local lane = profile[i]
          if lane then
            local flag = i == selectedLaneIdx
            if im.Selectable1(tostring(i), flag, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
              selectedLaneIdx = i
            end

            im.SameLine()
            im.NextColumn()

            -- 'Remove Selected Lane' button.
            if editor.uiIconImageButton(editor.icons.trashBin2, vec22, redB, nil, nil, 'removeSelectedLaneRight') then
              profileMgr.removeLane(selectedProfileIdx, i, 'right')
              updateRoadToNewProfile()
              roadMgr.setAuditionProfileDirty()
            end
            im.tooltip('Remove this lane from profile.')
            im.SameLine()
            im.NextColumn()

            -- 'Add New Lane Above' button.
            if editor.uiIconImageButton(editor.icons.vertical_align_top, vec22, greenB, nil, nil, 'addLaneAboveRight') then
              profileMgr.addLane(selectedProfileIdx, i, 'right', 'above')
              updateRoadToNewProfile()
              roadMgr.setAuditionProfileDirty()
            end
            im.tooltip('Add a new lane above this lane.')
            im.SameLine()
            im.NextColumn()

            -- 'Add New Lane Below' button.
            if editor.uiIconImageButton(editor.icons.vertical_align_bottom, vec22, greenB, nil, nil, 'addLaneBelowRight') then
              profileMgr.addLane(selectedProfileIdx, i, 'right', 'below')
              updateRoadToNewProfile()
              roadMgr.setAuditionProfileDirty()
            end
            im.tooltip('Add a new lane below this lane.')
            im.SameLine()
            im.NextColumn()

            -- 'Select New Lane Type' button.
            if editor.uiIconImageButton(editor.icons.fg_lt, vec22, blueB, nil, nil, 'selectLaneTypeRight1Button') then
              lane.type = profileMgr.cycleLaneTypeBack(lane.type)
              updateRoadToNewProfile()
              roadMgr.setAuditionProfileDirty()
            end
            im.tooltip('Cycle back through available lane types.')
            im.SameLine()
            im.NextColumn()

            -- Display the current type for this lane.
            im.Text(lane.type)
            im.SameLine()
            im.NextColumn()

            -- 'Select New Lane Type' button.
            if editor.uiIconImageButton(editor.icons.fg_gt, vec22, blueB, nil, nil, 'selectLaneTypeRight2Button') then
              lane.type = profileMgr.cycleLaneType(lane.type)
              updateRoadToNewProfile()
              roadMgr.setAuditionProfileDirty()
            end
            im.tooltip('Cycle forward through available lane types.')
            im.SameLine()
            im.NextColumn()

            -- Width input box.
            local oldWidth = lane.width[0]
            im.PushItemWidth(130)
            im.InputFloat("W###" .. tostring(wCtr), lane.width, 0.1, 0.0)
            wCtr = wCtr + 1
            im.tooltip('The lane width.')
            im.PopItemWidth()
            im.SameLine()
            im.NextColumn()
            lane.width = im.FloatPtr(max(1e-3, min(10.0, lane.width[0])))
            if lane.width[0] ~= oldWidth then
              updateRoadToNewProfile()
              roadMgr.setAuditionProfileDirty()
            end

            -- Relative height (left) input box.
            local oldHeightL = lane.heightL[0]
            im.PushItemWidth(130)
            im.InputFloat("H(L)###" .. tostring(wCtr), lane.heightL, 0.01, 0.0)
            wCtr = wCtr + 1
            im.tooltip('The relative height of the lane left edge.')
            im.PopItemWidth()
            im.SameLine()
            im.NextColumn()
            lane.heightL = im.FloatPtr(max(0.4, min(3.0, lane.heightL[0])))
            if lane.heightL[0] ~= oldHeightL then
              updateRoadToNewProfile()
              roadMgr.setAuditionProfileDirty()
            end

            -- Relative height (right) input box.
            local oldHeightR = lane.heightR[0]
            im.PushItemWidth(130)
            im.InputFloat("H(R)###" .. tostring(wCtr), lane.heightR, 0.01, 0.0)
            wCtr = wCtr + 1
            im.tooltip('The relative height of the right outer edge.')
            im.PopItemWidth()
            im.SameLine()
            im.Separator()
            im.NextColumn()
            lane.heightR = im.FloatPtr(max(0.4, min(3.0, lane.heightR[0])))
            if lane.heightR[0] ~= oldHeightR then
              updateRoadToNewProfile()
              roadMgr.setAuditionProfileDirty()
            end
          end
        end
        im.EndListBox()
      end
      im.Separator()
    else
      isProfileEditWinOpen = false
      if not isProfilesListWinOpen then
        profileMgr.goToOldView()
        roadMgr.removeHiddenRoads()
      end
    end
  end
end

-- Handles the groups list sub window.
local function handleGroupsListSubWindow()
  if isGroupsListWinOpen then
    if editor.beginWindow(groupsListWinName, "Prefab Groups###14") then

      im.Separator()

      if im.BeginListBox('', im.ImVec2(220, 180), im.WindowFlags_ChildWindow) then

        im.Columns(3, "groupsListBoxColumns", true)
        im.SetColumnWidth(0, 150)
        im.SetColumnWidth(1, 32)
        im.SetColumnWidth(2, 32)

        local numGroups = #groupMgr.groups
        for i = 1, numGroups do
          local group = groupMgr.groups[i]
          local flag = i == selectedGroupIdx
          if im.Selectable1(group.name, flag, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
            if selectedGroupIdx ~= i then
              selectedGroupIdx = i
              roadMgr.removeHiddenRoads()
              groupMgr.addGroupToRoadsAudition(i)
            end
          end
          im.SameLine()
          im.NextColumn()

          -- 'Pick Group' button.
          if editor.uiIconImageButton(editor.icons.add_box, vec19, redB, nil, nil, 'pickGroupButton') then
            isGroupPlaceMode = true
            isGroupsListWinOpen = false
            editor.hideWindow(groupsListWinName)
            groupMgr.goToOldView()
            roadMgr.removeHiddenRoads()
            pGroup = groupMgr.addGroupToRoadsPlace(i, isConformGroupToTerrain)
            selectedGroupIdx = i
          end
          im.tooltip('Place this prefab group.')
          im.SameLine()
          im.NextColumn()

          -- 'Save Group' button.
          if editor.uiIconImageButton(editor.icons.floppyDisk, vec19, blueB, nil, nil, 'pickGroupButton') then
            groupMgr.save(i)
          end
          im.tooltip('Save this prefab group to disk.')
          im.Separator()
          im.NextColumn()
        end
        im.EndListBox()
      end

      im.Columns(4, "groupsListColumns", true)
      im.SetColumnWidth(0, 40)
      im.SetColumnWidth(1, 40)
      im.SetColumnWidth(2, 80)
      im.SetColumnWidth(3, 80)

      -- 'Load Group' button.
      if editor.uiIconImageButton(editor.icons.folder, vec28, dullWhite, nil, nil, 'loadGroup') then
        groupMgr.load()
      end
      im.tooltip('Load prefab group from disk.')
      im.SameLine()
      im.NextColumn()

      -- 'Conform Group To Terrain' button.
      -- [Only available if a terrain block is present].
      local isConfGToRButtonCol = greenB
      if isConformGroupToTerrain then isConfGToRButtonCol = greenD end
      if terrain then
        if editor.uiIconImageButton(editor.icons.lineToTerrain, vec28, isConfGToRButtonCol, nil, nil, 'conformGroupToTerrainButton') then
          isConformGroupToTerrain = not isConformGroupToTerrain
        end
        im.tooltip('Conform the group to the terrain.')
      end
      im.SameLine()
      im.NextColumn()

      local oldVal1 = groupMgr.isPOline[0]
      im.Checkbox("Outline", groupMgr.isPOline)
      im.tooltip('Displays a mesh outline around the road.')
      im.SameLine()
      im.NextColumn()

      local oldVal2 = groupMgr.isPLane[0]
      im.Checkbox("Lanes", groupMgr.isPLane)
      im.tooltip('Displays lane directions/markings.')
      im.SameLine()
      im.NextColumn()
      if oldVal1 ~= groupMgr.isPOline[0]  or oldVal2 ~= groupMgr.isPLane[0] then
        groupMgr.changeAuditionMarkings()
      end

    else
      isGroupsListWinOpen = false -- handle close sub-window.
      editor.hideWindow(groupsListWinName)
      groupMgr.goToOldView()
      roadMgr.removeHiddenRoads()
    end
  end
end

-- Handles the import options sub-window.
local function handleImportSubWindow()
  if isImportWinOpen then
    if editor.beginWindow(importWinName, "Import Options###15") then

      if im.Checkbox("Offset To Terrain", importO2T) then
        if importO2T[0] then
          importCO = im.BoolPtr(false)
        end
      end
      im.tooltip('Apply vertical offset to imported road network, to sit on existing terrain.')

      im.Separator()

      if im.Checkbox("Use Custom Offset", importCO) then
        if importCO[0] then
          importO2T = im.BoolPtr(false)
        end
      end
      im.tooltip('Apply a custom vertical offset to imported road network.')

      if importCO[0] then
        im.PushItemWidth(130)
        im.InputFloat("Offset", importCustomOffset, 0.1, 0.0)
        im.tooltip('Sets the custom vertical offset amount.')
        im.PopItemWidth()
      end

      im.Separator()

      if terrain then
        im.Checkbox("Terraform Terrain To Import", importTT2I)
        im.tooltip('Terraform the terrain to fit the imported road network.')
      end

      if importTT2I[0] then
        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(233)
        im.SliderInt("###49", domainOfInfluence, 1, 500, "Domain Of Influence %d")
        im.PopItemWidth()
        im.PopStyleVar()
        im.tooltip('Set the domain of influence of the terraforming.')
      end

      if editor.uiIconImageButton(editor.icons.ab_asset_jbeam, vec28, nil, nil, nil, 'importFromImportWdw') then
        isImportWinOpen = false
        editor.hideWindow(importWinName)
        roadMgr.clearAllRoads()
        table.clear(profileMgr.profiles)
        profileMgr.populateProfileTemplates()
        table.clear(groupMgr.groups)
        groupMgr.getDefaultGroups()
        import.import(importO2T[0], importCO[0], importTT2I[0], importCustomOffset[0], domainOfInfluence[0])
      end
      im.tooltip('Import from file.')
    else
      isImportWinOpen = false -- handle close sub-window.
    end
  end
end

-- World editor main callback for rendering the UI.
local function onEditorGui()
  if not isRoadArchitectActive then
    return
  end

  -- Manage the updating of roads (geometry, meshes, decals, rendering).
  local roads, link = roadMgr.roads, linkMgr.link
  roadMgr.updateRoads(isGroupsListWinOpen)
  if not isFinalise then
    render.drawRoadMarkups(
      isGroupsListWinOpen, isProfilesListWinOpen, isCreateGroup, isMultiSelect, isMultiDone, isBulldoze, gPolygon, roadMgr.multi, isLinkMode, roads, roadMgr.map, link)
  end

  -- Cache the mouse state.
  local mousePos = util.mouseOnMapPos()
  local isMouseClickedL, isMouseClickedR, isMouseDownL = im.IsMouseClicked(0), im.IsMouseClicked(1), im.IsMouseDown(0)
  local dt = mouseTimer:stopAndReset()
  timeSinceLastClick = timeSinceLastClick + dt
  local isDoubleClick = isMouseClickedL and timeSinceLastClick < doubleClickTime
  if isMouseClickedL then
    timeSinceLastClick = 0.0
  end
  if isMouseDownL then
    heldTime = heldTime + dt
  else
    heldTime = 0.0
  end
  local hasMouseBeenDownAWhile = heldTime > dragStartTime

  -- Handle the gimabals.
  if selectedRoadIdx and selectedNodeIdx then
    local road = roads[selectedRoadIdx]
    if road then
      local node = road.nodes[selectedNodeIdx]
      if node then
        handleGimbals(node.p)
      end
    end
  end

  -- Handle the back-end (mode-specific functionality).
  if not isFinalise then
    if isBulldoze then                                                                              -- MODE #1: [bulldoze]: The user wants to remove roads/nodes.
      handleBulldoze(roads, mousePos, isMouseClickedL, isDoubleClick, isMouseClickedR)
    elseif isMultiSelect then                                                                       -- MODE #2: [multi select]: The user wants to draw a multi-select polygon.
      handleMultiSelect(roads, mousePos, isMouseClickedL, isDoubleClick, isMouseClickedR)
    elseif isCreateGroup then                                                                       -- MODE #3: [create group]: The user wants to create a new prefab group.
      handleCreateGroup(roads, mousePos, isMouseClickedL, isDoubleClick, isMouseClickedR)
    elseif isGroupPlaceMode then                                                                    -- MODE #4: [group placement]: The user wants to place a selected prefab group.
      handlePlaceGroup(roads, mousePos, isDoubleClick, isMouseDownL, isMouseClickedR)
    elseif isGroupsListWinOpen then                                                                 -- MODE #5: [groups editing]: The user wants to select prefab groups.
      time = groupMgr.goToGroupView(selectedGroupIdx, timer, time)
      time = time + timer:stopAndReset() * 0.001
      if time > spinTime then
        groupMgr.manageRotateCam()
        time = time - spinTime
      end
    elseif isProfilesListWinOpen or isProfileEditWinOpen then                                       -- MODE #6: [profile editing]: The user wants to edit lateral road profiles.
      time = profileMgr.goToProfileView(timer, time)
      time = time + timer:stopAndReset() * 0.001
      if time > spinTime then
        roadMgr.manageTempRoadSection(selectedProfileIdx)
        time = time - spinTime
      end
    elseif not isLinkMode then                                                                      -- MODE #7: [road]: The user wants to create/edit roads.
      handleCreateRoads(roads, mousePos, isMouseClickedL, isMouseDownL, isDoubleClick, hasMouseBeenDownAWhile)
    else                                                                                            -- MODE #8: [links]: The user wants to create links between roads.
      handleLinks(roads, link, isMouseClickedL)
    end
  end

  -- Handle the front-end (UI).
  -- [Manage the display of each window of the editor].
  handleMainToolWindow(roads, link)
  handleRoadsListSubWindow(roads, link)
  handleRoadEditSubWindow(roads)
  handleNodeEditSubWindow(roads)
  handleProfilesListSubWindow(roads)
  handleProfileEditSubWindow(roads)
  handleGroupsListSubWindow()
  handleImportSubWindow()

  -- Some preparation for the next iteration of the main loop callback.
  mouseLast = mousePos
end

-- Called when the 'Road Architect' icon is pressed.
local function onActivate()
  editor.clearObjectSelection()
  editor.showWindow(toolWinName)
  isRoadArchitectActive = true
end

-- Called when the 'Road Architect' is exited.
local function onDeactivate()

  -- First close down the profile list/groups list windows, if open.
  if isProfilesListWinOpen then
    isProfilesListWinOpen = false
    profileMgr.goToOldView()
    roadMgr.removeHiddenRoads()
  end
  if isGroupsListWinOpen then
    isGroupsListWinOpen = false
    groupMgr.goToOldView()
    roadMgr.removeHiddenRoads()
  end

  editor.hideWindow(toolWinName)
  editor.hideWindow(roadsListWinName)
  editor.hideWindow(roadEditWinName)
  editor.hideWindow(nodeEditWinName)
  editor.hideWindow(profilesListWinName)
  editor.hideWindow(profileEditWinName)
  editor.hideWindow(groupsListWinName)
  editor.hideWindow(importWinName)

  isRoadArchitectActive = false
  isRoadsListWinOpen, isRoadEditWinOpen, isNodeEditWinOpen = false, false, false
  isProfilesListWinOpen, isProfileEditWinOpen, isGroupsListWinOpen = false, false, false
  isImportWinOpen = false
end

-- Called upon world editor initialization.
local function onEditorInitialized()
  if tech_license.isValid() then
    editor.editModes.roadArchitectEditMode = {
      displayName = "Road Architect",
      onUpdate = nop,
      onActivate = onActivate,
      onDeactivate = onDeactivate,
      icon = editor.icons.autobahn,
      iconTooltip = "Road Architect",
      auxShortcuts = {},
      hideObjectIcons = true,
      sortOrder = 9004 }

    editor.registerWindow(toolWinName, toolWinSize)
    editor.registerWindow(roadsListWinName, roadsListWinSize)
    editor.registerWindow(roadEditWinName, roadEditWinSize)
    editor.registerWindow(nodeEditWinName, nodeEditWinSize)
    editor.registerWindow(profilesListWinName, profilesListWinSize)
    editor.registerWindow(profileEditWinName, profileEditWinSize)
    editor.registerWindow(groupsListWinName, groupsListWinSize)
    editor.registerWindow(importWinName, importWinSize)

    terrain = extensions.editor_terrainEditor.getTerrainBlock()                                     -- Get a reference to the terrain block, if it exists.
    profileMgr.populateProfileTemplates()                                                           -- Populate the default lateral road profile templates.
    groupMgr.getDefaultGroups()                                                                     -- Populate the default prefab groups.
  end
end

-- Serialization function.
local function onSerialize()

  -- First close down the profile list/groups list windows, if open.
  if isProfilesListWinOpen then
    isProfilesListWinOpen = false
    profileMgr.goToOldView()
    roadMgr.removeHiddenRoads()
  end
  if isGroupsListWinOpen then
    isGroupsListWinOpen = false
    groupMgr.goToOldView()
    roadMgr.removeHiddenRoads()
  end

  -- Gather the data which requires serialised.
  local serRoads, serProfiles, serGroups = {}, {}, {}
  local roads, profiles, groups = roadMgr.roads, profileMgr.profiles, groupMgr.groups
  local numRoads, numProfiles, numGroups = #roads, #profiles, #groups

  -- Serialise all the roads in the roads container.
  for i = 1, numRoads do
    serRoads[i] = roadMgr.serialiseRoad(roads[i])
  end

  -- Serialise all the profiles in the profiles container.
  for i = 1, numProfiles do
    serProfiles[i] = profileMgr.serialiseProfile(profiles[i])
  end

  -- Serialise all the prefab groups in the prefab groubs container.
  for i = 1, numGroups do
    serGroups[i] = groupMgr.serialiseGroup(groups[i])
  end

  -- Remove all meshes and decals from scene.
  roadMgr.removeAll()

  -- Compress the data, ready for the serialisation process to commence.
  local encodedData = { data = lpack.encode({
    roads = serRoads,
    profiles = serProfiles,
    groups = serGroups,
    history = terra.history })}
  jsonWriteFile(tempFilepath, encodedData, true)
  return { d = { name = 'roadArchitectSerializationData'} }
end

-- Deserialization function.
local function onDeserialized(dataIn)

  -- Collect the data which requires de-serialised.
  local loadedJson = jsonReadFile(tempFilepath)
  local data = lpack.decode(loadedJson.data)
  local serRoads, serProfiles, serGroups = data.roads, data.profiles, data.groups
  local numRoads, numProfiles, numGroups = #serRoads, #serProfiles, #serGroups

  -- De-serialise all the stored profiles, into the profiles container.
  table.clear(profileMgr.profiles)
  for i = 1, numProfiles do
    profileMgr.profiles[i] = profileMgr.deserialiseProfile(serProfiles[i])
  end

  -- De-serialise all the stored roads, into the roads container.
  table.clear(roadMgr.roads)
  for i = 1, numRoads do
    roadMgr.roads[i] = roadMgr.deserialiseRoad(serRoads[i])
  end
  roadMgr.recomputeMap()

  -- De-serialise all the stored prefab groups, into the prefab groups container.
  table.clear(groupMgr.groups)
  for i = 1, numGroups do
    groupMgr.groups[i] = groupMgr.deserialiseGroup(serGroups[i])
  end

  -- Compute the render data for all roads.
  roadMgr.computeAllRoadRenderData()
end


-- Public interface.
M.onEditorGui =                                           onEditorGui
M.onEditorInitialized =                                   onEditorInitialized
M.onSerialize =                                           onSerialize
M.onDeserialized =                                        onDeserialized

return M