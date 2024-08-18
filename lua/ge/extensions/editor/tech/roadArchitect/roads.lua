-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Module constants.
local nodeHeightLimit = 1000.0                                                                      -- The height limit for all road nodes, in metres.
local nodeRotLimit = 50.0                                                                           -- The lateral rotation limit for all road nodes, in degrees.
local splitRepelDist = 1.0                                                                          -- The distance by which to repel nodes after a split, in meters.
local tempRoadName = 'temp'                                                                         -- The name of the temporary road which is used for auditioning profiles.
local auditionHeight = 1000.0                                                                       -- The height above zero, at which the prefab groups are auditioned, in metres.
local camRotInc = math.pi / 500                                                                     -- The step size of the angle when rotating the camera around the audition center.

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}


-- External modules used.
local profileMgr = require('editor/tech/roadArchitect/profiles')                                    -- Manages the profiles structure/handles profile calculations.
local geom = require('editor/tech/roadArchitect/geometry')                                          -- A module for performing geometric calculations.
local roadMeshMgr = require('editor/tech/roadArchitect/roadMesh')                                   -- A module for managing procedural road meshes.
local staticMeshMgr = require('editor/tech/roadArchitect/staticMesh')                               -- A module for managing static meshes.
local decMgr = require('editor/tech/roadArchitect/decals')                                          -- A module for managing road decals.
local tMesh = require('editor/tech/roadArchitect/tunnelMesh')                                       -- Manages the road tunnel meshes.

-- Private constants.
local im = ui_imgui
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
local abs, sqrt, sin, cos, tan = math.abs, math.sqrt, math.sin, math.cos, math.tan
local twoPi = math.pi * 2.0
local downVec, up, tmp0, tmp1 = vec3(0, 0, -1), vec3(0, 0, 1), vec3(0, 0), vec3(0, 0)
local temp_P1, temp_P2 = vec3(-10, 0, auditionHeight), vec3(10, 0, auditionHeight)
local gView, auditionVec, auditionCamPos = vec3(0, 0), vec3(0, 0, auditionHeight), vec3(0, 0)
local camRotAngle = 0.0
local isPOline = im.BoolPtr(true)                                                                   -- In auditioning, a flag which stores if road outlines are to be visible.
local isPLane = im.BoolPtr(true)                                                                    -- In auditioning, a flag which stores if lane info is to be visible.

-- Public module state.
local roads = {}                                                                                    -- The collection of roads currently present in the scene.
local roadMap = {}                                                                                  -- A hash table which maps road names to index in the roads array.
local multi = {}                                                                                    -- A container for storing a multi-selection.
local isAuditionProfileDirty = false                                                                -- A flag indicating if changes have been made to the profile under audition.

-- Creates a new road from a given lateral profile.
local function createRoadFromProfile(profile)
  local laneKeys, leftKeys, rightKeys = profileMgr.computeLaneKeys(profile)
  return {

    -- Private.
    isHidden = false,                                                                               -- A flag which indicates if this road is hidden from the user (eg temp roads).
    isDirty = true,                                                                                 -- Indicates if a change has been made to this road, requiring updates.
    isMesh = false,                                                                                 -- Indicates if a procedural mesh will be rendered for this road, on finalise.

    renderData = nil,                                                                               -- A table containing all the world-space positions used for rendering.
    laneKeys = laneKeys, leftKeys = leftKeys, rightKeys = rightKeys,                                -- A table containg all the lane keys associated to this road.

    isArc = false,                                                                                  -- Indicates if this road is an arc road (or a spline road).
    isLinkRoad = false,                                                                             -- Indicates if this road is a link road (has limited functionality/behaviour).

    isDowelS = false, isDowelE = false,                                                             -- Flags which indicate if dowels should be used with the road start/end resp.

    startR = nil, startLie = nil, endR = nil, endLie = nil,                                         -- For link roads, these index the start/end connection road data (and their lie).
    l1 = {}, l2 = {},                                                                               -- The collection of lanes from each joining road, resp.

    idxL0a_1 = nil, idxL0a_2 = nil, idxL0a_l2 = nil, idxL0a_l = nil,                                -- [i. ontribution masks for each relevant point, for optimisation:]
    idxL0b_1 = nil, idxL0b_2 = nil, idxL0b_l2 = nil, idxL0b_l = nil,                                -- [1 = first, 2 = second, l2 = second last, l = last].
    idxR0a_1 = nil, idxR0a_2 = nil, idxR0a_l2 = nil, idxR0a_l = nil,
    idxR0b_1 = nil, idxR0b_2 = nil, idxR0b_l2 = nil, idxR0b_l = nil,

    idxL1 = nil, idxR1 = nil,                                                                       -- [ii. The renderData lane indices].
    idxL2 = nil, idxR2 = nil,                                                                       -- [iii. The renderData cross-sectional point indices].
    w1 = nil, w2 = nil,                                                                             -- [iv. The linked road width data].
    hL1 = nil, hL2 = nil, hR1 = nil, hR2 = nil,                                                     -- [v. The linked road relative height offset data].
    rot1 = nil, rot2 = nil,                                                                         -- [vi. The linked road rotational data].
    isLinkedToS = {}, isLinkedToE = {},                                                             -- The collections of roads to which this road is linked (at start and end).

    tunnels = {},                                                                                   -- The collection of tunnel sections belonging to this road.

    -- Public.
    name = worldEditorCppApi.generateUUID(),                                                        -- The unique id of the road.

    nodes = {},                                                                                     -- The collection of reference nodes for this road.

    profile = profile,                                                                              -- The lateral road profile associated with this road.

    targetLonRes = im.FloatPtr(5.0),                                                                -- The default target longitudinal resolution for the road.
    targetArcRes = im.FloatPtr(5.0),                                                                -- The default target circular arc resolution for the road.

    isConformRoadToTerrain = im.BoolPtr(false),                                                     -- Indicates if road should conform to the local terrain (inherit height).
    isDisplayRoadSurface = im.BoolPtr(true),                                                        -- Indicates if the road surface should be visualised (debugDraw)
    isDisplayRoadOutline = im.BoolPtr(true),                                                        -- Indicates if the road outline should be visualised (debugDraw).
    isDisplayNodeSpheres = im.BoolPtr(true),                                                        -- Indicates if the node spheres should be displayed at nodes (debugDraw).
    isDisplayNodeNumbers = im.BoolPtr(false),                                                       -- Indicates if the node number markups should be displayed (debugDraw).
    isDisplayLaneInfo = im.BoolPtr(true),                                                           -- Indicates if the lane markups should be displayed (debugDraw).
    isDisplayRefLine = im.BoolPtr(true),                                                            -- Indicates if the road reference line should be displayed (debugDraw).
    isRigidTranslation = im.BoolPtr(false),                                                         -- Indicates if fully-rigid translations are used when moving road nodes.
    isAllowTunnels = im.BoolPtr(false),                                                             -- Indicates if tunnels are allowed on this road (will appear automatically).

    isRefLineDecal = im.BoolPtr(true),                                                              -- Decals: Indicates if the road reference line decal will appear.
    isEdgeLineDecal = im.BoolPtr(true),                                                             -- Decals: Indicates if the road edge line decals will appear.
    isLaneDivsDecal = im.BoolPtr(true),                                                             -- Decals: Indicates if the road lane division decals will appear.
    isStartLineDecal = im.BoolPtr(false),                                                           -- Decals: Indicates if the road start line (at junction) decals will appear.
    isEndLineDecal = im.BoolPtr(false),                                                             -- Decals: Indicates if the road end line (at junction) decals will appear.
    edgeDecalDist = im.FloatPtr(0.12),                                                              -- Decals: The distance from the road edge to the edge decals, in meters.
    edgeDecalWidth = im.FloatPtr(0.15),                                                             -- Decals: The width of the road edge line decals, in meters.
    centerlineWidth = im.FloatPtr(0.3),                                                             -- Decals: The width of the road centerline decal, in meters.
    laneMarkingWidth = im.FloatPtr(0.15),                                                           -- Decals: The width of the lane division decals, in meters.
    jctLineWidth = im.FloatPtr(2.4),                                                                -- Decals: The width of the road start/end line decals, in meters.
    jctLineOffset = im.FloatPtr(1.5),                                                               -- Decals: The lateral offset of the road start/end line decals, in meters.

    forceField = im.FloatPtr(1.0),                                                                  -- The value of the force field (when using non-rigid translation).
    isCivilEngRoads = im.BoolPtr(false),                                                            -- Indicates if this road is using civil engineering style or spline style.

    lampPostLonSpacing = im.FloatPtr(20.0),                                                         -- Lamp Posts: Longitudinal spacing, in meters.
    lampJitter = im.FloatPtr(0.0),                                                                  -- Lamp Posts: The amount of random jitter used on lamp posts.
    lampPostLonOffset = im.FloatPtr(0.0),                                                           -- Lamp Posts: Longitudinal offset of the first lamp post, in meters.
    lampPostVertOffset = im.FloatPtr(0.5),                                                          -- Lamp Posts: Vertical offset of the lamp posts, in meters.

    crashPostLonOffset = im.FloatPtr(0.0),                                                          -- Crash Barriers: Longitudinal offset of the start of the barriers, in meters.
    crashVertOffset = im.FloatPtr(0.0),                                                             -- Crash Barriers: Vertical offset of the crash barriers, in meters.
    useDoublePlate = im.BoolPtr(false),                                                             -- Crash Barriers: Indicates whether to use double plates or single plates.

    barrierLonOffset = im.FloatPtr(0.0),                                                            -- Concrete Barriers: Longitudinal offset of the start of the barriers, in meters.
    barrierVertOffset = im.FloatPtr(0.0),                                                           -- Concrete Barriers: Vertical offset of the concrete barriers, in meters.

    fenceLonOffset = im.FloatPtr(0.0),                                                              -- Mesh Fences: Longitudinal offset of the start of the fences, in meters.
    fenceVertOffset = im.FloatPtr(0.1),                                                             -- Mesh Fences: Vertical offset of the mesh fences, in meters.

    bollardLonSpacing = im.FloatPtr(10.0),                                                          -- Bollards: Longitudinal spacing, in meters.
    bollardJitter = im.FloatPtr(0.0),                                                               -- Bollards: The amount of random jitter used on bollards.
    bollardLonOffset = im.FloatPtr(0.0),                                                            -- Bollards: Longitudinal offset of the first bollard, in meters.
    bollardVertOffset = im.FloatPtr(0.0),                                                           -- Bollards: Vertical offset of the bollards, in meters.

    radGran = im.IntPtr(15),                                                                        -- Tunnels: The radial granularity.
    radOffset = im.FloatPtr(0.0),                                                                   -- Tunnels: The radial offset.
    thickness = im.FloatPtr(1.0),                                                                   -- Tunnels: The wall thickness.
    zOffsetFromRoad = im.FloatPtr(0.0),                                                             -- Tunnels: The vertical offset, of the road inside the tunnel.
    protrudeS = im.FloatPtr(0.0),                                                                   -- Tunnels: The amount of protrusion along the tangent, at the start pos.
    protrudeE = im.FloatPtr(0.0),                                                                   -- Tunnels: The amount of protrusion along the tangent, at the end pos.
    extraS = im.IntPtr(2),                                                                          -- Tunnels: The start road position (the div point index).
    extraE = im.IntPtr(2) }                                                                         -- Tunnels: The end road position (the div point index).
end

-- Creates a new road from a given lateral profile template name.
local function createRoadFromTemplate(profileTemplateName)
  return createRoadFromProfile(profileMgr.createProfileFromTemplate(
    profileTemplateName,
    worldEditorCppApi.generateUUID()))
end

-- Handles the case when a road needs updated.
local function setDirty(r)
  r.isDirty = true                                                                                  -- First, set the selected road to dirty.
  local links = r.isLinkedToS                                                                       -- Check the roads which are linked to the start of this road.
  local numLinks = #links
  for i = 1, numLinks do
    local road = roads[roadMap[links[i]]]
    if road and road.isLinkRoad then                                                                -- Only link roads need updated - others are considered fixed until moved.
      road.isDirty = true                                                                           -- Set all the first-links of the selected road to dirty too.
    end
  end
  links = r.isLinkedToE                                                                             -- Check the roads which are linked to the end of this road.
  numLinks = #links
  for i = 1, numLinks do
    local road = roads[roadMap[links[i]]]
    if road and road.isLinkRoad then                                                                -- Only link roads need updated - others are considered fixed until moved.
      road.isDirty = true                                                                           -- Set all the first-links of the selected road to dirty too.
    end
  end
end

-- Sets the flag which indicates if the audition profiles needs updating, to true.
local function setAuditionProfileDirty()
  isAuditionProfileDirty = true
end

-- Adds a new node at the end of the road with the given index.
local function addNodeToRoad(rIdx, pos)
  local r = roads[rIdx]
  if r then
    local widths, heightsL, heightsR = profileMgr.getWAndHByKey(r.profile)
    r.nodes[#r.nodes + 1] = {
      p = pos,                                                                                      -- The node world-space position.
      isLocked = false,                                                                             -- Indicates if node is locked or unlocked (ie if can be moved by the user).
      rot = im.FloatPtr(0.0),                                                                       -- The lateral rotation angle of the normal at this node (sets road camber).
      widths = widths,                                                                              -- The widths of each lane, by lane key.
      heightsL = heightsL,                                                                          -- The left lane height of each lane, by lane key.
      heightsR = heightsR,                                                                          -- The right lane height of each lane, by lane key.
      incircleRad = im.FloatPtr(1.0),                                                               -- The radius of the incircle, in [0.1, 2] (used for civil eng style roads).
      offset = 0.0 }                                                                                -- The lateral lane offset at this node.
    setDirty(r)
  end
end

-- Deep copies a node.
local function copyNode(n)
  local wC, hLC, hRC, w, hL, hR = {}, {}, {}, n.widths, n.heightsL, n.heightsR
  for i = -20, 20 do
    if w[i] then
      wC[i], hLC[i], hRC[i] = im.FloatPtr(w[i][0]), im.FloatPtr(hL[i][0]), im.FloatPtr(hR[i][0])
    end
  end
  local pos = n.p
  return {
    p = vec3(pos.x, pos.y, pos.z),
    isLocked = n.isLocked,
    rot = im.FloatPtr(n.rot[0]),
    widths = wC, heightsL = hLC, heightsR = hRC,
    incircleRad = im.FloatPtr(n.incircleRad[0]),
    offset = n.offset }
end

-- Updates the width/relative height offset for the given road (in all nodes), after changing the lateral road profile.
local function updateWAndHToNewProfile(road)
  local nodes = road.nodes
  local numNodes = #nodes
  for i = 1, numNodes do
    nodes[i].widths, nodes[i].heightsL, nodes[i].heightsR = profileMgr.getWAndHByKey(road.profile)
  end
end

-- Computes the 2D axis-aligned bounding box of the road with the given id.
-- [The profile width is also included in the computation, rather than just the nodes themselves].
local function computeAABB2D(rIdx)
  local road = roads[rIdx]
  local width = profileMgr.getWidth(road.profile)
  local nodes, xMin, xMax, yMin, yMax = road.nodes, 1e24, -1e24, 1e24, -1e24
  local numNodes = #nodes
  for i = 1, numNodes do
    local p = nodes[i].p
    local px, py = p.x, p.y
    xMin, xMax, yMin, yMax = min(xMin, px), max(xMax, px), min(yMin, py), max(yMax, py)
  end
  return { xMin = xMin - width, xMax = xMax + width, yMin = yMin - width, yMax = yMax + width }
end

-- Computes the 2D axis-aligned bounding box of all roads together.
local function computeAABB2DAllRoads()
  local xMin, xMax, yMin, yMax = 1e24, -1e24, 1e24, -1e24
  for _, road in ipairs(roads) do
    local width = profileMgr.getWidth(road.profile)
    local nodes = road.nodes
    local numNodes = #nodes
    for i = 1, numNodes do
      local p = nodes[i].p
      local px, py = p.x, p.y
      xMin, xMax, yMin, yMax = min(xMin, px - width), max(xMax, px + width), min(yMin, py - width), max(yMax, py + width)
    end
  end
  return { xMin = xMin, xMax = xMax, yMin = yMin, yMax = yMax }
end

-- Re-computes the map (hash-table) between road names and index in the roads array.
local function recomputeMap()
  table.clear(roadMap)
  local numRoads = #roads
  for i = 1, numRoads do
    roadMap[roads[i].name] = i
  end
end

-- Removes the road with the given id from the scene.
local function removeRoad(roadName)

  -- If this road is joined to any other road, remove the link on the other road.
  local idx = roadMap[roadName]
  local road = roads[idx]
  if road then
    local rLinksS, rLinksE = road.isLinkedToS, road.isLinkedToE
    local numLinksS, numLinksE = #rLinksS, #rLinksE
    for j = 1, numLinksS do                                                                         -- Handle the roads linked to the start of this road.
      local lRoad = roads[roadMap[rLinksS[j]]]
      if lRoad and (lRoad.startR == roadName or lRoad.endR == roadName) and lRoad.isLinkRoad then
        removeRoad(lRoad.name)
      end
    end
    for j = 1, numLinksE do                                                                         -- Handle the roads linked to the end of this road.
      local lRoad = roads[roadMap[rLinksE[j]]]
      if lRoad and (lRoad.startR == roadName or lRoad.endR == roadName) and lRoad.isLinkRoad then
        removeRoad(lRoad.name)
      end
    end

    -- Remove the road mesh from the scene, and the roads array entry.
    roadMeshMgr.tryRemove(roadName)
    staticMeshMgr.tryRemove(roadName)                                                               -- If any static mesh was created for this road on finalise, remove them now.
    table.remove(roads, idx)

    -- Remove all links to this road, which may appear in other roads.
    for _, v in pairs(roads) do
      road = roads[v]
      if road then
        rLinksS, rLinksE = road.isLinkedToS, road.isLinkedToE
        numLinksS, numLinksE = #rLinksS, #rLinksE
        for j = numLinksS, 1, -1 do                                                                 -- Handle the roads linked to the start of this road.
          if rLinksS[j] == roadName then
            table.remove(rLinksS, j)
          end
        end
        for j = numLinksE, 1, -1 do                                                                 -- Handle the roads linked to the end of this road.
          if rLinksE[j] == roadName then
            table.remove(rLinksE, j)
          end
        end
      end
    end
  end

  -- Search for any link roads which are unconnected at either end, and remove them.
  for _, v in pairs(roads) do
    local r = roads[v]
    if r and r.isLinkRoad then
      local sR, eR = r.startR, r.endR
      if not roadMap[sR] or not roadMap[eR] or not roads[roadMap[sR]] or not roads[roadMap[eR]] then
        removeRoad(r.name)
      end
    end
  end

  -- Re-compute the road map.
  recomputeMap()
end

-- Removes the node with the given node id, from the road with the given road id.
local function removeNode(rIdx, nIdx)
  local road = roads[rIdx]
  table.remove(road.nodes, nIdx)
end

-- Deep copies a table of nodal width values.
local function copyWAndH(widths, heightsL, heightsR)
  local wCopy, hLCopy, hRCopy = {}, {}, {}
  for i = -20, 20 do
    local w = widths[i]
    if w then
      wCopy[i] = im.FloatPtr(w[0])
      hLCopy[i], hRCopy[i] = im.FloatPtr(heightsL[i][0]), im.FloatPtr(heightsR[i][0])
    end
  end
  return wCopy, hLCopy, hRCopy
end

-- Produces a table of average widths, from two width tables.
local function averageWidths(w1, w2, hL1, hL2, hR1, hR2)
  local wAvg, hLAvg, hRAvg = {}, {}, {}
  for i = -20, 20 do
    local wLane1, wLane2 = w1[i], w2[i]
    local hLLane1, hLLane2, hRLane1, hRLane2 = hL1[i], hL2[i], hR1[i], hR2[i]
    if wLane1 then
      wAvg[i] = im.FloatPtr((wLane1[0] + wLane2[0]) * 0.5)
      hLAvg[i] = im.FloatPtr((hLLane1[0] + hLLane2[0]) * 0.5)
      hRAvg[i] = im.FloatPtr((hRLane1[0] + hRLane2[0]) * 0.5)
    end
  end
  return wAvg, hLAvg, hRAvg
end

-- Adds a node between the currently-selected node and the next node.
-- [The added node is computed as the midpoint of the two nodes].
local function addIntermediateNode(rIdx, nIdx)
  local nodes = roads[rIdx].nodes
  local nIdxPlus1 = nIdx + 1
  local n1, n2 = nodes[nIdx], nodes[nIdxPlus1]
  local w, hL, hR = averageWidths(n1.widths, n2.widths, n1.heightsL, n2.heightsL, n1.heightsR, n2.heightsR)
  local newNode = {
    p = (n1.p + n2.p) * 0.5,                                                                        -- The new point is the midpoint between the selected node and the next node.
    isLocked = false,                                                                               -- The new node will be unlocked by default.
    rot = im.FloatPtr((n1.rot[0] + n2.rot[0]) * 0.5),                                               -- The rest of the values are averaged between the selected node and next node.
    widths = w, heightsL = hL, heightsR = hR,
    incircleRad = im.FloatPtr((n1.incircleRad[0] + n2.incircleRad[0]) * 0.5),
    offset = (n1.offset + n2.offset) * 0.5 }
  table.insert(nodes, nIdxPlus1, newNode)
end

-- Removes all road from the scene.
local function clearAllRoads(link)
  while #roads > 0 do
    removeRoad(roads[1].name, link)
  end
end

-- Sets all roads in the network to use meshes (instead of only decals).
local function setAllMesh()
  local numRoads = #roads
  for i = 1, numRoads do
    roads[i].isMesh = true
  end
end

-- Sets all roads in the network to use only decals (no procedural meshes).
local function setAllDecals()
  local numRoads = #roads
  for i = 1, numRoads do
    roads[i].isMesh = false
  end
end

-- Removes all hidden roads from the roads container.
local function removeHiddenRoads()
  local numRoads = #roads
  for i = numRoads, 1, -1 do
    local r = roads[i]
    if r.isHidden then
      roadMeshMgr.tryRemove(r.name)
      staticMeshMgr.tryRemove(r.name)                                                               -- If any static mesh was created for this road on finalise, remove them now.
      table.remove(roads, i)
    end
  end

  -- Re-compute the road map.
  recomputeMap()
end

-- Moves the camera to directly above the road with the given index.
local function goToRoad(rIdx)

  -- Compute the 2D axis-aligned bounding box of the given road.
  -- [We also compute the largest height value].
  local xMin, xMax, yMin, yMax, zMax = 1e24, -1e24, 1e24, -1e24, -1e24
  local road = roads[rIdx]
  local nodes = road.nodes
  local numNodes = #nodes
  for i = 1, numNodes do
    local p = nodes[i].p
    local px, py = p.x, p.y
    xMin, xMax = min(xMin, px), max(xMax, px)
    yMin, yMax = min(yMin, py), max(yMax, py)
    zMax = max(zMax, p.z)
  end

  -- If road is too small (eg one node), do nothing.
  if abs(xMax - xMin) < 0.1 and abs(yMax - yMin) < 0.1 then
    return
  end

  -- Determine the required distance which the camera should be at.
  local midX, midY = (xMin + xMax) * 0.5, (yMin + yMax) * 0.5                                       -- Midpoint of axis-aligned bounding box.
  tmp0:set(midX, midY, 0.0)
  tmp1:set(xMax, yMax, 0.0)
  local groundDist = tmp0:distance(tmp1)                                                            -- The largest distance from the center of the box to the outside.
  local halfFov = core_camera.getFovRad() * 0.5                                                     -- Half the camera field of view (in radians).
  local height = groundDist / tan(halfFov) + zMax + 5.0                                             -- The height that the camera should be to fit all the trajectory in view.
  local rot = quatFromDir(downVec)

  -- Move the camera to the appropriate pose.
  commands.setFreeCamera()
  core_camera.setPosRot(0, midX, midY, height, rot.x, rot.y, rot.z, rot.w)
end

-- Performs a translation upon the road with the given index.
-- [The manner by which the road is translated depends on various road/node properties].
local function moveRoad(road, nodeIdx, mouseNow, mouseLast)

  -- Split into cases: [Rigid Translation] or [Force-Field Translation].
  local nodes, v = road.nodes, mouseNow - mouseLast
  local numNodes = #nodes
  if road.isRigidTranslation[0] then
    for i = 1, numNodes do                                                                          -- CASE A: [Rigid Translation].
      if not nodes[i].isLocked then
        nodes[i].p = nodes[i].p + v
      end
    end
  else
    -- First, move the central node to the mouse position.
    local cNode, fieldInv = nodes[nodeIdx], 1.0 / max(1e-7, road.forceField[0])                     -- CASE B: [Force-Field Translation].
    cNode.p = mouseNow

    -- Iterate from just below the central node, to the start of the polyline.
    for i = max(1, nodeIdx - 1), 1, -1 do
      local n = nodes[i]
      if n.isLocked then                                                                            -- Do not go beyond any locked node in the -ve direction.
        break
      end
      n.p = n.p + v * min(1.0, max(0.0, 1.0 - cNode.p:distance(n.p) * fieldInv))                    -- Move this node by a distance-based ratio (based on the force field).
    end

    -- Iterate from just above the central node, to the end of the polyline.
    for i = min(numNodes, nodeIdx + 1), numNodes do
      local n = nodes[i]
      if n.isLocked then                                                                            -- Do not go beyond and locked node in the +ve direction.
        break
      end
      n.p = n.p + v * min(1.0, max(0.0, 1.0 - cNode.p:distance(n.p) * fieldInv))                    -- Move this node by a distance-based ratio (based on the force field).
    end
  end

  setDirty(road)
end

-- Performs a height adjustment to the road with the given index.
-- [The manner by which the road height is adjusted depends on various road/node properties].
local function adjustHeight(hNew, hOld, nIdx, rIdx)

  local road = roads[rIdx]
  local nodes, dz = road.nodes, hNew - hOld
  local numNodes = #nodes

  -- First, adjust the central node to the mouse position.
  local cNode, fieldInv = nodes[nIdx], 1.0 / max(1e-7, road.forceField[0])                          -- CASE A: [Force-Field Translation].
  cNode.p.z = hNew
  cNode.p.z = min(nodeHeightLimit, max(-nodeHeightLimit, cNode.p.z))

  -- Now adjust the rest of the nodes, as appropriate.
  if nodeHeightLimit - abs(cNode.p.z) > 1e-3 then                                                   -- If the central node is maxed out, do not move the other nodes.
    if road.isRigidTranslation[0] then
      for i = 1, numNodes do                                                                        -- CASE B: [Rigid Translation].
        if i ~= nIdx then
          nodes[i].p.z = nodes[i].p.z + dz
          nodes[i].p.z = min(nodeHeightLimit, max(-nodeHeightLimit, nodes[i].p.z))
        end
      end
    else
      -- Iterate from just below the central node, to the start of the polyline.
      for i = nIdx - 1, 1, -1 do
        local n = nodes[i]
        if n.isLocked then                                                                          -- Do not go beyond any locked node in the -ve direction.
          break
        end
        n.p.z = n.p.z + dz * min(1.0, max(0.0, 1.0 - cNode.p:distance(n.p) * fieldInv))             -- Move this node by a distance-based ratio (based on the force field).
        n.p.z = min(nodeHeightLimit, max(-nodeHeightLimit, n.p.z))
      end

      -- Iterate from just above the central node, to the end of the polyline.
      for i = nIdx + 1, numNodes do
        local n = nodes[i]
        if n.isLocked then                                                                          -- Do not go beyond and locked node in the +ve direction.
          break
        end
        n.p.z = n.p.z + dz * min(1.0, max(0.0, 1.0 - cNode.p:distance(n.p) * fieldInv))             -- Move this node by a distance-based ratio (based on the force field).
        n.p.z = min(nodeHeightLimit, max(-nodeHeightLimit, n.p.z))
      end
    end
  end
  setDirty(road)
end

-- Performs a lateral rotation upon the road with the given index.
-- [The manner by which the road is rotated depends on various road/node properties].
local function adjustLateralRotation(rotNew, rotOld, nIdx, rIdx)

  local road = roads[rIdx]
  local nodes, dRot = road.nodes, rotNew - rotOld
  local numNodes = #nodes

  -- First, rotate the central node to the mouse position.
  local cNode, fieldInv = nodes[nIdx], 1.0 / max(1e-7, road.forceField[0])                          -- CASE: [Force-Field Translation].
  cNode.rot = im.FloatPtr(cNode.rot[0] + dRot)
  cNode.rot = im.FloatPtr(min(nodeRotLimit, max(-nodeRotLimit, cNode.rot[0])))

  -- Now rotate the rest of the nodes, as appropriate.
  if nodeRotLimit - abs(cNode.rot[0]) > 1e-3 then                                                   -- If the central node is maxed out, do not move the other nodes.

    if road.isRigidTranslation[0] then
      for i = 1, numNodes do                                                                        -- CASE: [Rigid Translation].
        if i ~= nIdx then
          nodes[i].rot = im.FloatPtr(nodes[i].rot[0] + dRot)
          nodes[i].rot = im.FloatPtr(min(nodeRotLimit, max(-nodeRotLimit, nodes[i].rot[0])))
        end
      end
    else

      -- Iterate from just below the central node, to the start of the polyline.
      for i = nIdx - 1, 1, -1 do
        local n = nodes[i]
        if n.isLocked then                                                                          -- Do not go beyond any locked node in the -ve direction.
          break
        end
        local rat = min(1.0, max(0.0, 1.0 - cNode.p:distance(n.p) * fieldInv))
        n.rot = im.FloatPtr(n.rot[0] + dRot * rat)                                                  -- Move this node by a distance-based ratio (based on the force field).
        n.rot = im.FloatPtr(min(nodeRotLimit, max(-nodeRotLimit, n.rot[0])))
      end

      -- Iterate from just above the central node, to the end of the polyline.
      for i = nIdx + 1, numNodes do
        local n = nodes[i]
        if n.isLocked then                                                                          -- Do not go beyond and locked node in the +ve direction.
          break
        end
        local rat = min(1.0, max(0.0, 1.0 - cNode.p:distance(n.p) * fieldInv))
        n.rot = im.FloatPtr(n.rot[0] + dRot * rat)                                                  -- Move this node by a distance-based ratio (based on the force field).
        n.rot = im.FloatPtr(min(nodeRotLimit, max(-nodeRotLimit, n.rot[0])))
      end
    end
  end
  setDirty(road)
end

-- Un-links the start point of the given road, and removes any associated link roads there.
local function unlinkStart(road)
  local lS = road.isLinkedToS
  local numLS = #lS
  for i = 1, numLS do
    removeRoad(lS[i])
  end
end

-- Un-links the end point of the given road, and removes any associated link roads there.
local function unlinkEnd(road)
  local lE = road.isLinkedToE
  local numLE = #lE
  for i = 1, numLE do
    removeRoad(lE[i])
  end
end

-- Deep copies a road.
local function copyRoad(r)

  -- Deep copy the nodes.
  local nodesCopy, nodes = {}, r.nodes
  local numNodes = #nodes
  for i = 1, numNodes do
    nodesCopy[i] = copyNode(nodes[i])
  end

  -- Deep copy the connectivity data.
  local l1, l2, rL1, rL2 = {}, {}, r.l1, r.l2
  for i = -20, 20 do
    l1[i], l2[i] = rL1[i], rL2[i]
  end
  local linkedS, linkedE, linkedSLen, linkedELen = {}, {}, #r.isLinkedToS, #r.isLinkedToE
  for i = 1, linkedSLen do
    linkedS[i] = r.isLinkedToS[i]
  end
  for i = 1, linkedELen do
    linkedE[i] = r.isLinkedToE[i]
  end

  -- Populate the deep copy.
  local rCopy = {}
  rCopy.name = r.name
  rCopy.profile = profileMgr.copyProfile(r.profile)
  rCopy.tunnels = {}
  rCopy.nodes = nodesCopy
  rCopy.isHidden = r.isHidden
  rCopy.isDirty = true
  rCopy.isMesh = r.isMesh
  rCopy.isDowelS, rCopy.isDowelE = r.isDowelS, r.isDowelE
  rCopy.laneKeys, rCopy.leftKeys, rCopy.rightKeys = profileMgr.computeLaneKeys(r.profile)
  rCopy.renderData = nil
  rCopy.isLinkRoad = r.isLinkRoad
  rCopy.isArc = r.isArc
  rCopy.startR, rCopy.startLie, rCopy.endR, rCopy.endLie = r.startR, r.startLie, r.endR, r.endLie
  rCopy.l1, rCopy.l2 = l1, l2
  rCopy.isLinkedToS, rCopy.isLinkedToE = linkedS, linkedE
  rCopy.idxL0a_1, rCopy.idxL0a_2, rCopy.idxL0a_l2, rCopy.idxL0a_l = r.idxL0a_1, r.idxL0a_2, r.idxL0a_l2, r.idxL0a_l
  rCopy.idxL0b_1, rCopy.idxL0b_2, rCopy.idxL0b_l2, rCopy.idxL0b_l = r.idxL0b_1, r.idxL0b_2, r.idxL0b_l2, r.idxL0b_l
  rCopy.idxR0a_1, rCopy.idxR0a_2, rCopy.idxR0a_l2, rCopy.idxR0a_l = r.idxR0a_1, r.idxR0a_2, r.idxR0a_l2, r.idxR0a_l
  rCopy.idxR0b_1, rCopy.idxR0b_2, rCopy.idxR0b_l2, rCopy.idxR0b_l = r.idxR0b_1, r.idxR0b_2, r.idxR0b_l2, r.idxR0b_l
  rCopy.idxL1, rCopy.idxL2, rCopy.idxR1, rCopy.idxR2 = r.idxL1, r.idxL2, r.idxR1, r.idxR2
  rCopy.w1, rCopy.w2, rCopy.rot1, rCopy.rot2 = r.w1, r.w2, r.rot1, r.rot2
  rCopy.hL1, rCopy.hL2, rCopy.hR1, rCopy.hR2 = r.hL1, r.hL2, r.hR1, r.hR2
  rCopy.targetLonRes = im.FloatPtr(r.targetLonRes[0])
  rCopy.targetArcRes = im.FloatPtr(r.targetArcRes[0])
  rCopy.isConformRoadToTerrain = im.BoolPtr(r.isConformRoadToTerrain[0])
  rCopy.isDisplayRoadSurface = im.BoolPtr(r.isDisplayRoadSurface[0])
  rCopy.isDisplayRoadOutline = im.BoolPtr(r.isDisplayRoadOutline[0])
  rCopy.isDisplayNodeSpheres = im.BoolPtr(r.isDisplayNodeSpheres[0])
  rCopy.isDisplayNodeNumbers = im.BoolPtr(r.isDisplayNodeNumbers[0])
  rCopy.isDisplayLaneInfo = im.BoolPtr(r.isDisplayLaneInfo[0])
  rCopy.isDisplayRefLine = im.BoolPtr(r.isDisplayRefLine[0])
  rCopy.isAllowTunnels = im.BoolPtr(r.isAllowTunnels[0])
  rCopy.isRefLineDecal = im.BoolPtr(r.isRefLineDecal[0])
  rCopy.isEdgeLineDecal = im.BoolPtr(r.isEdgeLineDecal[0])
  rCopy.isLaneDivsDecal = im.BoolPtr(r.isLaneDivsDecal[0])
  rCopy.isStartLineDecal = im.BoolPtr(r.isStartLineDecal[0])
  rCopy.isEndLineDecal = im.BoolPtr(r.isEndLineDecal[0])
  rCopy.edgeDecalDist = im.FloatPtr(r.edgeDecalDist[0])
  rCopy.edgeDecalWidth = im.FloatPtr(r.edgeDecalWidth[0])
  rCopy.centerlineWidth = im.FloatPtr(r.centerlineWidth[0])
  rCopy.laneMarkingWidth = im.FloatPtr(r.laneMarkingWidth[0])
  rCopy.jctLineWidth = im.FloatPtr(r.jctLineWidth[0])
  rCopy.jctLineOffset = im.FloatPtr(r.jctLineOffset[0])
  rCopy.isRigidTranslation = im.BoolPtr(r.isRigidTranslation[0])
  rCopy.forceField = im.FloatPtr(r.forceField[0])
  rCopy.isCivilEngRoads = im.BoolPtr(r.isCivilEngRoads[0])

  rCopy.radGran = im.IntPtr(r.radGran[0])
  rCopy.radOffset = im.FloatPtr(r.radOffset[0])
  rCopy.thickness = im.FloatPtr(r.thickness[0])
  rCopy.zOffsetFromRoad = im.FloatPtr(r.zOffsetFromRoad[0])
  rCopy.protrudeS = im.FloatPtr(r.protrudeS[0])
  rCopy.protrudeE = im.FloatPtr(r.protrudeE[0])
  rCopy.extraS = im.IntPtr(r.extraS[0])
  rCopy.extraE = im.IntPtr(r.extraE[0])

  rCopy.lampPostLonSpacing = im.FloatPtr(r.lampPostLonSpacing[0])
  rCopy.lampJitter = im.FloatPtr(r.lampJitter[0])
  rCopy.lampPostLonOffset = im.FloatPtr(r.lampPostLonOffset[0])
  rCopy.lampPostVertOffset = im.FloatPtr(r.lampPostVertOffset[0])

  rCopy.crashPostLonOffset = im.FloatPtr(r.crashPostLonOffset[0])
  rCopy.crashVertOffset = im.FloatPtr(r.crashVertOffset[0])
  rCopy.useDoublePlate = im.BoolPtr(r.useDoublePlate[0])

  rCopy.barrierLonOffset = im.FloatPtr(r.barrierLonOffset[0])
  rCopy.barrierVertOffset = im.FloatPtr(r.barrierVertOffset[0])

  rCopy.fenceLonOffset = im.FloatPtr(r.fenceLonOffset[0])
  rCopy.fenceVertOffset = im.FloatPtr(r.fenceVertOffset[0])

  rCopy.bollardLonSpacing = im.FloatPtr(r.bollardLonSpacing[0])
  rCopy.bollardJitter = im.FloatPtr(r.bollardJitter[0])
  rCopy.bollardLonOffset = im.FloatPtr(r.bollardLonOffset[0])
  rCopy.bollardVertOffset = im.FloatPtr(r.bollardVertOffset[0])

  return rCopy
end

-- Splits the road with the given index, at the given node position.
-- [This can be used for creating junctions].
local function splitRoad(rIdx, nIdx, link)

  -- Cache the old road data.
  local r = roads[rIdx]
  local oldName, nodes, profile = r.name, r.nodes, r.profile
  local isArc = r.isArc
  local targetLonRes, targetArcRes = r.targetLonRes[0], r.targetArcRes[0]
  local isConformRoadToTerrain = r.isConformRoadToTerrain[0]
  local isDisplayRoadSurface = r.isDisplayRoadSurface[0]
  local isDisplayRoadOutline = r.isDisplayRoadOutline[0]
  local isDisplayNodeSpheres = r.isDisplayNodeSpheres[0]
  local isDisplayNodeNumbers = r.isDisplayNodeNumbers[0]
  local isDisplayLaneInfo = r.isDisplayLaneInfo[0]
  local isDisplayRefLine = r.isDisplayRefLine[0]
  local isAllowTunnels = r.isAllowTunnels[0]
  local isRefLineDecal = r.isRefLineDecal[0]
  local isEdgeLineDecal = r.isEdgeLineDecal[0]
  local isLaneDivsDecal = r.isLaneDivsDecal[0]
  local isStartLineDecal = r.isStartLineDecal[0]
  local isEndLineDecal = r.isEndLineDecal[0]
  local isRigidTranslation = r.isRigidTranslation[0]
  local forceField = r.forceField[0]
  local isCivilEngRoads = r.isCivilEngRoads[0]

  -- Create the first new road (road A).
  local copiedNodesA = {}
  for i = 1, nIdx do
    copiedNodesA[i] = copyNode(nodes[i])
  end
  local roadA = createRoadFromProfile(profile)
  roadA.nodes = copiedNodesA
  roadA.tunnels = {}
  roadA.isLinkRoad, roadA.isArc = false, isArc
  roadA.isDowelS, roadA.isDowelE = r.isDowelS, false
  roadA.laneKeys, roadA.leftKeys, roadA.rightKeys = profileMgr.computeLaneKeys(r.profile)
  roadA.startR, roadA.startLie, roadA.endR, roadA.endLie = r.startR, r.startLie, nil, nil
  roadA.idxL0a_1, roadA.idxL0a_2, roadA.idxL0a_l2, roadA.idxL0a_l = r.idxL0a_1, r.idxL0a_2, r.idxL0a_l2, r.idxL0a_l
  roadA.idxL0b_1, roadA.idxL0b_2, roadA.idxL0b_l2, roadA.idxL0b_l = r.idxL0b_1, r.idxL0b_2, r.idxL0b_l2, r.idxL0b_l
  roadA.idxR0a_1, roadA.idxR0a_2, roadA.idxR0a_l2, roadA.idxR0a_l = r.idxR0a_1, r.idxR0a_2, r.idxR0a_l2, r.idxR0a_l
  roadA.idxR0b_1, roadA.idxR0b_2, roadA.idxR0b_l2, roadA.idxR0b_l = r.idxR0b_1, r.idxR0b_2, r.idxR0b_l2, r.idxR0b_l
  roadA.idxL1, roadA.idxL2, roadA.idxR1, roadA.idxR2 = r.idxL1, r.idxL2, nil, nil
  roadA.w1, roadA.w2, roadA.rot1, roadA.rot2 = r.w1, r.w2, r.rot1, r.rot2
  roadA.hL1, roadA.hL2, roadA.hR1, roadA.hR2 = r.hL1, r.hL2, r.hR1, r.hR2
  roadA.l1, roadA.l2 = r.l1, {}
  roadA.isLinkedToS, roadA.isLinkedToE = r.isLinkedToS, {}
  roadA.targetLonRes = im.FloatPtr(targetLonRes)
  roadA.targetArcRes = im.FloatPtr(targetArcRes)
  roadA.isConformRoadToTerrain = im.BoolPtr(isConformRoadToTerrain)
  roadA.isDisplayRoadSurface = im.BoolPtr(isDisplayRoadSurface)
  roadA.isDisplayRoadOutline = im.BoolPtr(isDisplayRoadOutline)
  roadA.isDisplayNodeSpheres = im.BoolPtr(isDisplayNodeSpheres)
  roadA.isDisplayNodeNumbers = im.BoolPtr(isDisplayNodeNumbers)
  roadA.isDisplayLaneInfo = im.BoolPtr(isDisplayLaneInfo)
  roadA.isDisplayRefLine = im.BoolPtr(isDisplayRefLine)
  roadA.isAllowTunnels = im.BoolPtr(isAllowTunnels)
  roadA.isRefLineDecal = im.BoolPtr(isRefLineDecal)
  roadA.isEdgeLineDecal = im.BoolPtr(isEdgeLineDecal)
  roadA.isLaneDivsDecal = im.BoolPtr(isLaneDivsDecal)
  roadA.isStartLineDecal = im.BoolPtr(isStartLineDecal)
  roadA.isEndLineDecal = im.BoolPtr(isEndLineDecal)
  roadA.edgeDecalDist = im.FloatPtr(r.edgeDecalDist[0])
  roadA.edgeDecalWidth = im.FloatPtr(r.edgeDecalWidth[0])
  roadA.centerlineWidth = im.FloatPtr(r.centerlineWidth[0])
  roadA.laneMarkingWidth = im.FloatPtr(r.laneMarkingWidth[0])
  roadA.jctLineWidth = im.FloatPtr(r.jctLineWidth[0])
  roadA.jctLineOffset = im.FloatPtr(r.jctLineOffset[0])
  roadA.isRigidTranslation = im.BoolPtr(isRigidTranslation)
  roadA.forceField = im.FloatPtr(forceField)
  roadA.isCivilEngRoads = im.BoolPtr(isCivilEngRoads)

  roadA.radGran = im.IntPtr(r.radGran[0])
  roadA.radOffset = im.FloatPtr(r.radOffset[0])
  roadA.thickness = im.FloatPtr(r.thickness[0])
  roadA.zOffsetFromRoad = im.FloatPtr(r.zOffsetFromRoad[0])
  roadA.protrudeS = im.FloatPtr(r.protrudeS[0])
  roadA.protrudeE = im.FloatPtr(r.protrudeE[0])
  roadA.extraS = im.IntPtr(r.extraS[0])
  roadA.extraE = im.IntPtr(r.extraE[0])

  roadA.lampPostLonSpacing = im.FloatPtr(r.lampPostLonSpacing[0])
  roadA.lampJitter = im.FloatPtr(r.lampJitter[0])
  roadA.lampPostLonOffset = im.FloatPtr(r.lampPostLonOffset[0])
  roadA.lampPostVertOffset = im.FloatPtr(r.lampPostVertOffset[0])

  roadA.crashPostLonOffset = im.FloatPtr(r.crashPostLonOffset[0])
  roadA.crashVertOffset = im.FloatPtr(r.crashVertOffset[0])
  roadA.useDoublePlate = im.BoolPtr(r.useDoublePlate[0])

  roadA.barrierLonOffset = im.FloatPtr(r.barrierLonOffset[0])
  roadA.barrierVertOffset = im.FloatPtr(r.barrierVertOffset[0])

  roadA.fenceLonOffset = im.FloatPtr(r.fenceLonOffset[0])
  roadA.fenceVertOffset = im.FloatPtr(r.fenceVertOffset[0])

  roadA.bollardLonSpacing = im.FloatPtr(r.bollardLonSpacing[0])
  roadA.bollardJitter = im.FloatPtr(r.bollardJitter[0])
  roadA.bollardLonOffset = im.FloatPtr(r.bollardLonOffset[0])
  roadA.bollardVertOffset = im.FloatPtr(r.bollardVertOffset[0])

  -- Create the second new road (road B).
  local copiedNodesB, numNodes, ctr = {}, #nodes, 1
  for i = nIdx, numNodes do
    copiedNodesB[ctr] = copyNode(nodes[i])
    ctr = ctr + 1
  end
  local roadB = createRoadFromProfile(profileMgr.copyProfile(profile))
  roadB.nodes = copiedNodesB
  roadB.tunnels = {}
  roadB.isLinkRoad, roadB.isArc = false, isArc
  roadB.isDowelS, roadB.isDowelE = false, r.isDowelE
  roadB.laneKeys, roadB.leftKeys, roadB.rightKeys = profileMgr.computeLaneKeys(r.profile)
  roadB.startR, roadB.startLie, roadB.endR, roadB.endLie = nil, nil, r.endR, r.endLie
  roadB.idxL0a_1, roadB.idxL0a_2, roadB.idxL0a_l2, roadB.idxL0a_l = r.idxL0a_1, r.idxL0a_2, r.idxL0a_l2, r.idxL0a_l
  roadB.idxL0b_1, roadB.idxL0b_2, roadB.idxL0b_l2, roadB.idxL0b_l = r.idxL0b_1, r.idxL0b_2, r.idxL0b_l2, r.idxL0b_l
  roadB.idxR0a_1, roadB.idxR0a_2, roadB.idxR0a_l2, roadB.idxR0a_l = r.idxR0a_1, r.idxR0a_2, r.idxR0a_l2, r.idxR0a_l
  roadB.idxR0b_1, roadB.idxR0b_2, roadB.idxR0b_l2, roadB.idxR0b_l = r.idxR0b_1, r.idxR0b_2, r.idxR0b_l2, r.idxR0b_l
  roadB.idxL1, roadB.idxL2, roadB.idxR1, roadB.idxR2 = nil, nil, r.idxR1, r.idxR2
  roadB.w1, roadB.w2, roadB.rot1, roadB.rot2 = r.w1, r.w2, r.rot1, r.rot2
  roadB.hL1, roadB.hL2, roadB.hR1, roadB.hR2 = r.hL1, r.hL2, r.hR1, r.hR2
  roadB.l1, roadB.l2 = {}, r.l2
  roadB.isLinkedToS, roadB.isLinkedToE = {}, r.isLinkedToE
  roadB.targetLonRes = im.FloatPtr(targetLonRes)
  roadB.targetArcRes = im.FloatPtr(targetArcRes)
  roadB.isConformRoadToTerrain = im.BoolPtr(isConformRoadToTerrain)
  roadB.isDisplayRoadSurface = im.BoolPtr(isDisplayRoadSurface)
  roadB.isDisplayRoadOutline = im.BoolPtr(isDisplayRoadOutline)
  roadB.isDisplayNodeSpheres = im.BoolPtr(isDisplayNodeSpheres)
  roadB.isDisplayNodeNumbers = im.BoolPtr(isDisplayNodeNumbers)
  roadB.isDisplayRefLine = im.BoolPtr(isDisplayRefLine)
  roadB.isAllowTunnels = im.BoolPtr(isAllowTunnels)
  roadB.isRefLineDecal = im.BoolPtr(isRefLineDecal)
  roadB.isEdgeLineDecal = im.BoolPtr(isEdgeLineDecal)
  roadB.isLaneDivsDecal = im.BoolPtr(isLaneDivsDecal)
  roadB.isStartLineDecal = im.BoolPtr(isStartLineDecal)
  roadB.isEndLineDecal = im.BoolPtr(isEndLineDecal)
  roadB.isDisplayLaneInfo = im.BoolPtr(isDisplayLaneInfo)
  roadB.edgeDecalDist = im.FloatPtr(r.edgeDecalDist[0])
  roadB.edgeDecalWidth = im.FloatPtr(r.edgeDecalWidth[0])
  roadB.centerlineWidth = im.FloatPtr(r.centerlineWidth[0])
  roadB.laneMarkingWidth = im.FloatPtr(r.laneMarkingWidth[0])
  roadB.jctLineWidth = im.FloatPtr(r.jctLineWidth[0])
  roadB.jctLineOffset = im.FloatPtr(r.jctLineOffset[0])
  roadB.isRigidTranslation = im.BoolPtr(isRigidTranslation)
  roadB.forceField = im.FloatPtr(forceField)
  roadB.isCivilEngRoads = im.BoolPtr(isCivilEngRoads)

  roadB.radGran = im.IntPtr(r.radGran[0])
  roadB.radOffset = im.FloatPtr(r.radOffset[0])
  roadB.thickness = im.FloatPtr(r.thickness[0])
  roadB.zOffsetFromRoad = im.FloatPtr(r.zOffsetFromRoad[0])
  roadB.protrudeS = im.FloatPtr(r.protrudeS[0])
  roadB.protrudeE = im.FloatPtr(r.protrudeE[0])
  roadB.extraS = im.IntPtr(r.extraS[0])
  roadB.extraE = im.IntPtr(r.extraE[0])

  roadB.lampPostLonSpacing = im.FloatPtr(r.lampPostLonSpacing[0])
  roadB.lampJitter = im.FloatPtr(r.lampJitter[0])
  roadB.lampPostLonOffset = im.FloatPtr(r.lampPostLonOffset[0])
  roadB.lampPostVertOffset = im.FloatPtr(r.lampPostVertOffset[0])

  roadB.crashPostLonOffset = im.FloatPtr(r.crashPostLonOffset[0])
  roadB.crashVertOffset = im.FloatPtr(r.crashVertOffset[0])
  roadB.useDoublePlate = im.BoolPtr(r.useDoublePlate[0])

  roadB.barrierLonOffset = im.FloatPtr(r.barrierLonOffset[0])
  roadB.barrierVertOffset = im.FloatPtr(r.barrierVertOffset[0])

  roadB.fenceLonOffset = im.FloatPtr(r.fenceLonOffset[0])
  roadB.fenceVertOffset = im.FloatPtr(r.fenceVertOffset[0])

  roadB.bollardLonSpacing = im.FloatPtr(r.bollardLonSpacing[0])
  roadB.bollardJitter = im.FloatPtr(r.bollardJitter[0])
  roadB.bollardLonOffset = im.FloatPtr(r.bollardLonOffset[0])
  roadB.bollardVertOffset = im.FloatPtr(r.bollardVertOffset[0])

  -- Repel the two split endpoints slightly.
  local np = nodes[nIdx].p
  local tgtA, tgtB = nodes[nIdx - 1].p - np, nodes[nIdx + 1].p - np
  tgtA:normalize()
  tgtB:normalize()
  roadA.nodes[nIdx].p = roadA.nodes[nIdx].p + tgtA * splitRepelDist
  roadB.nodes[1].p = roadB.nodes[1].p + tgtB * splitRepelDist

  -- Add the two new roads and remove the old road.
  local numRoads = #roads
  local rIdxA, rIdxB = numRoads + 1, numRoads + 2
  roads[rIdxA], roads[rIdxB] = roadA, roadB
  roadMap[roadA.name], roadMap[roadB.name] = rIdxA, rIdxB
  roadMeshMgr.tryRemove(oldName)
  staticMeshMgr.tryRemove(oldName)                                                                  -- If any static mesh was created for this road on finalise, remove them now.
  table.remove(roads, rIdx)

  -- Change the references in any connected link roads, so they become aware of the split.
  numRoads = #roads
  for i = 1, numRoads do
    local r = roads[i]
    if r.isLinkRoad then
      if r.startR == oldName then
        local p0 = r.nodes[1].p
        if p0:squaredDistance(roadA.nodes[1].p) < p0:squaredDistance(roadB.nodes[#roadB.nodes].p) then
          r.startR = roadA.name
        else
          r.startR = roadB.name
        end
      end
      if r.endR == oldName then
        local p0 = r.nodes[#r.nodes].p
        if p0:squaredDistance(roadA.nodes[1].p) < p0:squaredDistance(roadB.nodes[#roadB.nodes].p) then
          r.endR = roadA.name
        else
          r.endR = roadB.name
        end
      end
      local lS, lE = r.isLinkedToS, r.isLinkedToE
      local numLS, numLE = #lS, #lE
      for i = 1, numLS do
        if lS[i] == oldName then
          local p0 = r.nodes[1].p
          if p0:squaredDistance(roadA.nodes[1].p) < p0:squaredDistance(roadB.nodes[#roadB.nodes].p) then
            lS[i] = roadA.name
          else
            lS[i] = roadB.name
          end
        end
      end
      for i = 1, numLE do
        if lE[i] == oldName then
          local p0 = r.nodes[#r.nodes].p
          if p0:squaredDistance(roadA.nodes[1].p) < p0:squaredDistance(roadB.nodes[#roadB.nodes].p) then
            lE[i] = roadA.name
          else
            lE[i] = roadB.name
          end
        end
      end
    end
  end

  -- Re-compute the road map.
  recomputeMap()
end

-- Flips the direction of the road with the given index.
-- [This will change the lateral position of the road reference line, and may be useful for fixing import errors].
local function flipRoad(rIdx)
  local r = roads[rIdx]
  local nodes, poly, ctr = r.nodes, {}, 1
  for i = #nodes, 1, -1 do
    poly[ctr] = nodes[i]
    ctr = ctr + 1
  end
  if r.renderData then
    table.clear(r.renderData)
  end
  r.nodes = poly
  geom.computeRoadRenderData(r, roads, roadMap)
end

-- Manages the updating of roads.
-- [Updates the render data for all roads which require it].
local function updateRoads(isGroupMode)
  local numRoads = #roads
  if isGroupMode then
    for i = 1, numRoads do                                                                          -- CASE A: group-mode
      local r = roads[i]
      if r.isDirty and #r.nodes > 1 then                                                            -- If the road has been marked as requiring updating.
        geom.computeRoadRenderData(r, roads, roadMap)                                               -- Compute the relevant geometric data needed for rendering the road.
        r.isDirty = false                                                                           -- The road has been updated, so we mark this in the road instance.
      end
    end
  else
    for i = 1, numRoads do                                                                          -- CASE B: Non-group-mode
      local r = roads[i]
      if r.isDirty and #r.nodes > 1 then                                                            -- If the road has been marked as requiring updating.
        geom.computeRoadRenderData(r, roads, roadMap)                                               -- Compute the relevant geometric data needed for rendering the road.
        if r.isMesh and not r.isHidden then                                                         -- Update the procedural mesh for this road, if this is switched on.
        end
        r.isDirty = false                                                                           -- The road has been updated, so we mark this in the road instance.
      end
    end
  end
end

-- Recover the holemap after the removal of a tunnel.
local function recoverHolemap(holes)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local xMinG, xMaxG, yMinG, yMaxG = 1e99, -1e99, 1e99, -1e99
  local done = {}
  if holes then
    local numHoles = #holes
    for i = 1, numHoles do
      local hs = holes[i]
      local p = hs.p
      local x, y = p.x, p.y
      if not done[x] or not done[x][y] then
        xMinG, xMaxG, yMinG, yMaxG = min(xMinG, x), max(xMaxG, x), min(yMinG, y), max(yMaxG, y)
        tb:setMaterialIdxWs(p, hs.i)
        if not done[x] then
          done[x] = {}
        end
        done[x][y] = true
      end
    end
  end

  -- Update the terrain block.
  local gMin, gMax = Point2I(0, 0), Point2I(0, 0)
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  te:worldToGridByPoint2I(vec3(xMinG, yMinG), gMin, tb)
  te:worldToGridByPoint2I(vec3(xMaxG, yMaxG), gMax, tb)
  local w2gMin, w2gMax = vec3(gMin.x, gMin.y), vec3(gMax.x, gMax.y)
  tb:updateGridMaterials(w2gMin, w2gMax)
  tb:updateGrid(w2gMin, w2gMax)
end

-- Removes all road meshes from the scene and clears the roads structure.
local function removeAll()
  decMgr.tryRemoveAll()                                                                             -- First, remove all decals, if any exist.
  local numRoads = #roads
  for i = 1, numRoads do
    local roadName = roads[i].name
    roadMeshMgr.tryRemove(roadName)                                                                 -- Remove all meshes, if any exist.
    staticMeshMgr.tryRemove(roadName)                                                               -- If any static mesh was created for this road on finalise, remove them now.
    local tunnels = roads[i].tunnels
    for j = 1, #tunnels do
      local t = tunnels[j]
      tMesh.tryRemove(t.name)
      recoverHolemap(t.holes)
    end
  end
  table.clear(roads)                                                                                -- Clear the roads container.
  recomputeMap()                                                                                    -- Re-compute the roads map.
end

-- Updates the camera position upon changing of audition group.
local function updateCameraPose()
  gView:set(0.0, 30.0, auditionHeight + 15.0)
  local gRot = quatFromDir(auditionVec - gView)
  commands.setFreeCamera()
  core_camera.setPosRot(0, gView.x, gView.y, gView.z, gRot.x, gRot.y, gRot.z, gRot.w)
end

-- Rotate the audition camera around the audition centroid.
local function rotateAuditionCamera(ang)
  local x, y, s, c = gView.x, gView.y, sin(ang), cos(ang)
  auditionCamPos:set(x * c - y * s, x * s + y * c, gView.z)
  local gRot = quatFromDir(auditionVec - auditionCamPos)
  core_camera.setPosRot(0, auditionCamPos.x, auditionCamPos.y, auditionCamPos.z, gRot.x, gRot.y, gRot.z, gRot.w)
end

-- Creates/updates a temporary linear road section, used for displaying and editing profiles.
local function manageTempRoadSection(pIdx)

  -- Fetch the selected lateral road profile.
  local profile = profileMgr.profiles[pIdx]

  -- Fetch the index of the temp road.
  local rIdx = roadMap[tempRoadName]
  if not rIdx or isAuditionProfileDirty then
    isAuditionProfileDirty = false
    local widths, heightsL, heightsR = profileMgr.getWAndHByKey(profile)
    local n1 = {
      p = temp_P1, isLocked = true, rot = im.FloatPtr(0.0),
      widths = widths, heightsL = heightsL, heightsR = heightsR,
      incircleRad = im.FloatPtr(1.0), offset = 0.0 }
    local n2 = {
      p = temp_P2, isLocked = true, rot = im.FloatPtr(0.0),
      widths = widths, heightsL = heightsL, heightsR = heightsR,
      incircleRad = im.FloatPtr(1.0), offset = 0.0 }
    local laneKeys, leftKeys, rightKeys = profileMgr.computeLaneKeys(profile)
    if not rIdx then
      rIdx = #roads + 1
    end
    roads[rIdx] = {
      isHidden = true,
      renderData = nil,
      laneKeys = laneKeys, leftKeys = leftKeys, rightKeys = rightKeys,
      isDirty = true,
      isMesh = false,
      isLinkRoad = false,
      isDowelS = false, isDowelE = false,
      isArc = false,
      startR = nil, startLie = nil, endR = nil, endLie = nil, l1 = {}, l2 = {},
      idxL0a_1 = nil, idxL0a_2 = nil, idxL0a_l2 = nil, idxL0a_l = nil,
      idxL0b_1 = nil, idxL0b_2 = nil, idxL0b_l2 = nil, idxL0b_l = nil,
      idxR0a_1 = nil, idxR0a_2 = nil, idxR0a_l2 = nil, idxR0a_l = nil,
      idxR0b_1 = nil, idxR0b_2 = nil, idxR0b_l2 = nil, idxR0b_l = nil,
      idxL1 = nil, idxL2 = nil, idxR1 = nil, idxR2 = nil,
      w1 = nil, w2 = nil,
      hL1 = nil, hL2 = nil, hR1 = nil, hR2 = nil,
      rot1 = nil, rot2 = nil,
      isLinkedToS = {}, isLinkedToE = {},
      type = nil,
      name = tempRoadName,
      nodes = { n1, n2 },
      tunnels = {},
      profile = profile,
      targetLonRes = im.FloatPtr(5.0),
      targetArcRes = im.FloatPtr(5.0),
      isConformRoadToTerrain = im.BoolPtr(false),
      isDisplayRoadSurface = im.BoolPtr(true),
      isDisplayRoadOutline = im.BoolPtr(isPOline[0]),
      isDisplayNodeSpheres = im.BoolPtr(false),
      isDisplayRefLine = im.BoolPtr(isPOline[0]),
      isAllowTunnels = im.BoolPtr(false),
      isDisplayLaneInfo = im.BoolPtr(isPLane),
      isDisplayNodeNumbers = im.BoolPtr(false),
      isRefLineDecal = im.BoolPtr(false),
      isEdgeLineDecal = im.BoolPtr(false),
      isLaneDivsDecal = im.BoolPtr(false),
      isStartLineDecal = im.BoolPtr(false),
      isEndLineDecal = im.BoolPtr(false),
      edgeDecalDist = im.FloatPtr(0.12),
      edgeDecalWidth = im.FloatPtr(0.1),
      centerlineWidth = im.FloatPtr(0.1),
      laneMarkingWidth = im.FloatPtr(0.1),
      jctLineWidth = im.FloatPtr(0.1),
      jctLineOffset = im.FloatPtr(0.0),
      isRigidTranslation = im.BoolPtr(false),
      forceField = im.FloatPtr(1.0),
      isCivilEngRoads = im.BoolPtr(false),

      radGran = im.IntPtr(15),
      radOffset = im.FloatPtr(0.0),
      thickness = im.FloatPtr(1.0),
      zOffsetFromRoad = im.FloatPtr(0.0),
      protrudeS = im.FloatPtr(0.0),
      protrudeE = im.FloatPtr(0.0),
      extraS = im.IntPtr(2),
      extraE = im.IntPtr(2),

      lampPostLonSpacing = im.FloatPtr(10.0),
      lampJitter = im.FloatPtr(0.0),
      lampPostLonOffset = im.FloatPtr(0.0),
      lampPostVertOffset = im.FloatPtr(0.0),

      crashPostLonOffset = im.FloatPtr(0.0),
      crashVertOffset = im.FloatPtr(0.0),
      useDoublePlate = im.BoolPtr(false),

      barrierLonOffset = im.FloatPtr(0.0),
      barrierVertOffset = im.FloatPtr(0.0),

      fenceLonOffset = im.FloatPtr(0.0),
      fenceVertOffset = im.FloatPtr(0.0),

      bollardLonSpacing = im.FloatPtr(10.0),
      bollardJitter = im.FloatPtr(0.0),
      bollardLonOffset = im.FloatPtr(0.0),
      bollardVertOffset = im.FloatPtr(0.0)}

    -- Recompute the road map.
    recomputeMap()

    -- Compute the render data and update the road mesh.
    geom.computeRoadRenderData(roads[rIdx], roads, roadMap)

    updateCameraPose()
  end

  rotateAuditionCamera(camRotAngle)
  camRotAngle = camRotAngle + camRotInc
  if camRotAngle > twoPi then
    camRotAngle = camRotAngle - twoPi
  end
end

-- Create a multi-select (from given polygon) and allow it to be manipulated.
local function createMultiSelect(gPolygon)

  -- Convert and copy the polygon to 2D.
  local poly2D = {}
  for i = 1, #gPolygon do
    local p = gPolygon[i]
    poly2D[i] = vec3(p.x, p.y, 0.0)
  end

  -- Collect all nodes (from all roads) which are inside the polygon.
  -- [This is stored in this module, as a table with road and node indices for each node].
  table.clear(multi)
  local ctr = 1
  for i = 1, #roads do
    local nodes = roads[i].nodes
    for j = 1, #nodes do
      if nodes[j].p:inPolygon(poly2D) then
        multi[ctr] = { r = i, n = j }
        ctr = ctr + 1
      end
    end
  end
end

-- Re-computes the road render data, for all roads, from fresh.
-- [This is used upon loading/de-serialisation, since link roads require renderdata for their attachment roads].
local function computeAllRoadRenderData()
  local numRoads = #roads                                                                           -- First compute the render data for non-link roads.
  for i = 1, numRoads do
    local r = roads[i]
    if not r.isLinkRoad and #r.nodes > 1 then
      geom.computeRoadRenderData(r, roads, roadMap)
    end
  end
  for i = 1, numRoads do                                                                            -- Then compute the render data for link roads.
    local r = roads[i]
    if r.isLinkRoad and #r.nodes > 1 then
      geom.computeRoadRenderData(r, roads, roadMap)
    end
  end
end

-- Bulldozes (removes) all nodes/roads inside the given polygon.
-- [If only part of a road is inside polygon, road will be split appropriately].
local function bulldoze(gPolygon)

  -- Convert and copy the polygon to 2D.
  local poly2D = {}
  for i = 1, #gPolygon do
    local p = gPolygon[i]
    poly2D[i] = vec3(p.x, p.y, 0.0)
  end

  for k, v in pairs(roadMap) do
    local r = roads[v]
    if r then
      local nodes = r.nodes
      local numNodes, nodeCtr = #nodes, 0
      for j = 1, #nodes do
        if nodes[j].p:inPolygon(poly2D) then
          nodeCtr = nodeCtr + 1
        end
      end
      if nodeCtr == numNodes then                                                                   -- All nodes of this road are inside the polygon, so remove the road.
        removeRoad(r.name)
      end
    end
  end
end

-- Vertically-offsets all roads to the terrain.
local function offsetRoads2Terrain()
  for _, road in ipairs(roads) do
    road.isConformRoadToTerrain = im.BoolPtr(true)
    setDirty(road)
  end
end

-- Vertically-offsets all roads to a custom value.
local function offsetByValue(offset)
  for _, road in ipairs(roads) do
    local nodes = road.nodes
    local numNodes = #nodes
    for i = 1, numNodes do
      nodes[i].p.z = nodes[i].p.z + offset
    end
    setDirty(road)
  end
end

-- Pierces (edits) the holemap with respect to the given tunnel.
-- [Any height plateau inside the tunnel will be converted to a hole].
local function pierceHolemap(t, rData)

  -- Determine the pipe center and lateral edge indices.
  local rD1, cIdx1, cIdx2, lIdx, rIdx = rData[1], -1, 3, nil, nil
  if not rD1[-1] then
    cIdx1, cIdx2 = 1, 4
  end
  for i = -20, 20 do
    if rD1[i] then
      lIdx = i
      break
    end
  end
  for i = 20, -20, -1 do
    if rD1[i] then
      rIdx = i
      break
    end
  end

  -- Compute the ring at each longitudinal point in the given section.
  local iStart, iEnd, radOffset, zOffsetFromRoad = t.s, t.e, t.radOffset, t.zOffsetFromRoad
  local zVec, roadLen = up * zOffsetFromRoad, #rData
  local numRings = iEnd - iStart + 1
  local pipe = {}
  for i = 1, numRings do
    local idx = iStart - 1 + i
    local rD = rData[idx]
    local rTan = rData[min(roadLen, idx + 1)][cIdx1][cIdx2] - rData[max(1, idx - 1)][cIdx1][cIdx2]
    rTan:normalize()                                                                                -- The road unit tangent vector.
    local rDLeft = rD[lIdx]
    local rLeft, rRight = rDLeft[4], rD[rIdx][3]                                                    -- The left-most and right-most lateral road points.
    local rCen = (rLeft + rRight) * 0.5                                                             -- The road lateral center.
    local rWidth = rLeft:distance(rRight)                                                           -- The (lateral) road width at this longitudinal point.
    pipe[i] = {
      r = rWidth + radOffset,                                                                       -- The radius of the pipe at this longitudinal point.
      cen = rCen + zVec,                                                                            -- The pipe center.
      tan = rTan }                                                                                  -- The pipe unit tangent vector.
  end

  -- Iterate across each section of the pipe, and determine if the heightmap intersects it.
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local granFac = 2
  local holes, hCtr = {}, 1
  local xMinG, xMaxG, yMinG, yMaxG = 1e99, -1e99, 1e99, -1e99
  local cenS, cenE, tanS, tanE = pipe[1].cen, pipe[numRings].cen, pipe[1].tan, pipe[numRings].tan
  for i = 2, numRings do
    local pipe1, pipe2 = pipe[i - 1], pipe[i]
    local r1, c1, r2, c2 = pipe1.r, pipe1.cen, pipe2.r, pipe2.cen
    local xMin, xMax = floor(min(c1.x - r1, c2.x - r2)), ceil(max(c1.x + r1, c2.x + r2))            -- The 2D AABB of this section, with a radial margin included.
    local yMin, yMax = floor(min(c1.y - r1, c2.y - r2)), ceil(max(c1.y + r1, c2.y + r2))
    xMinG, xMaxG, yMinG, yMaxG = min(xMinG, xMin), max(xMaxG, xMax), min(yMinG, yMin), max(yMaxG, yMax)
    local rAvg = (r1 + r2) * 0.5
    local rAvgSq = rAvg * rAvg
    local dx, dy = xMax - xMin, yMax - yMin
    local xGran, yGran = dx * granFac, dy * granFac
    local xFac, yFac = dx / xGran, dy / yGran
    for xxx = 0, xGran do                                                                           -- Iterate over the 2D AABB, and find any intersections.
      local xx = xMin + xxx * xFac
      local sx1, sx2 = floor(xx), ceil(xx)
      for yyy = 0, yGran do
        local yy = yMin + yyy * yFac
        local sy1, sy2 = floor(yy), ceil(yy)
        tmp0:set(sx1, sy1, 0)
        tmp1:set(sx1, sy1, core_terrain.getTerrainHeight(tmp0))
        local dSq = tmp1:squaredDistanceToLineSegment(c1, c2)
        if (i < 5 and (tmp1 - cenS):dot(tanS) > 0.0) or (i > numRings - 5 and (tmp1 - cenE):dot(tanE) < 0.0) or (i > 4 and i < numRings - 4) then   -- At ends, use plane clipping.
          if dSq < rAvgSq then
            holes[hCtr] = { p = vec3(tmp1.x, tmp1.y, 0), i = tb:getMaterialIdxWs(tmp1) }
            hCtr = hCtr + 1
            tb:setMaterialIdxWs(tmp1, 255)
          end
        end

        tmp0:set(sx1, sy2, 0)
        tmp1:set(sx1, sy2, core_terrain.getTerrainHeight(tmp0))
        local dSq = tmp1:squaredDistanceToLineSegment(c1, c2)
        if (i < 5 and (tmp1 - cenS):dot(tanS) > 0.0) or (i > numRings - 5 and (tmp1 - cenE):dot(tanE) < 0.0) or (i > 4 and i < numRings - 4) then   -- At ends, use plane clipping.
          if dSq < rAvgSq then
            holes[hCtr] = { p = vec3(tmp1.x, tmp1.y, 0), i = tb:getMaterialIdxWs(tmp1) }
            hCtr = hCtr + 1
            tb:setMaterialIdxWs(tmp1, 255)
          end
        end

        tmp0:set(sx2, sy1, 0)
        tmp1:set(sx2, sy1, core_terrain.getTerrainHeight(tmp0))
        local dSq = tmp1:squaredDistanceToLineSegment(c1, c2)
        if (i < 5 and (tmp1 - cenS):dot(tanS) > 0.0) or (i > numRings - 5 and (tmp1 - cenE):dot(tanE) < 0.0) or (i > 4 and i < numRings - 4) then   -- At ends, use plane clipping.
          if dSq < rAvgSq then
            holes[hCtr] = { p = vec3(tmp1.x, tmp1.y, 0), i = tb:getMaterialIdxWs(tmp1) }
            hCtr = hCtr + 1
            tb:setMaterialIdxWs(tmp1, 255)
          end
        end

        tmp0:set(sx2, sy2, 0)
        tmp1:set(sx2, sy2, core_terrain.getTerrainHeight(tmp0))
        local dSq = tmp1:squaredDistanceToLineSegment(c1, c2)
        if (i < 5 and (tmp1 - cenS):dot(tanS) > 0.0) or (i > numRings - 5 and (tmp1 - cenE):dot(tanE) < 0.0) or (i > 4 and i < numRings - 4) then   -- At ends, use plane clipping.
          if dSq < rAvgSq then
            holes[hCtr] = { p = vec3(tmp1.x, tmp1.y, 0), i = tb:getMaterialIdxWs(tmp1) }
            hCtr = hCtr + 1
            tb:setMaterialIdxWs(tmp1, 255)
          end
        end
      end
    end
  end

  -- Update the terrain block.
  local gMin, gMax = Point2I(0, 0), Point2I(0, 0)
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  te:worldToGridByPoint2I(vec3(xMinG, yMinG), gMin, tb)
  te:worldToGridByPoint2I(vec3(xMaxG, yMaxG), gMax, tb)
  local w2gMin, w2gMax = vec3(gMin.x, gMin.y), vec3(gMax.x, gMax.y)
  tb:updateGridMaterials(w2gMin, w2gMax)
  tb:updateGrid(w2gMin, w2gMax)

  return holes
end

-- Switches to the 'finalised' state.
-- [All requested procedural meshes are created, the collision mesh is re-computed, then all requested decals are laid].
local function finalise()

  computeAllRoadRenderData()

  -- First, create all the requested procedural road and tunnel meshes.
  local numRoads = #roads
  for i = 1, numRoads do
    local r = roads[i]
    if #r.nodes > 1 then
      roadMeshMgr.createRoad(r, i)
      staticMeshMgr.createStaticMeshes(r, i)
      if #r.tunnels > 0 then
        for j = 1, #r.tunnels do
          local t = r.tunnels[j]
          t.name = worldEditorCppApi.generateUUID()
          tMesh.createTunnel(t.name, r.renderData, t)                                               -- Create the procedural mesh for this tunnel.
          t.holes = pierceHolemap(t, r.renderData)                                                  -- Edit the holemap with respect to this tunnel.
        end
      end
    end
  end

  -- Now that the meshes exist in the scene, re-compute the collision mesh to take them into account.
  be:reloadCollision()

  -- Lastly, now that the collision meshes has been updated, lay down all the requested decals.
  for i = 1, numRoads do
    local r = roads[i]
    if #r.nodes > 1 then
      decMgr.createDecal(r, i, numRoads)
    end
  end

  -- Reload the navgraph.
  map.reset()
end

-- Leaves the 'finalised' state and returns to the 'edit' state.
local function unfinalise()
  local numRoads = #roads
  for i = 1, numRoads do
    local road = roads[i]
    local roadName = road.name
    decMgr.tryRemove(roadName)                                                                      -- If any decal was created for this road on finalise, remove it now.
    roadMeshMgr.tryRemove(roadName)                                                                 -- If any mesh was created for this road on finalise, remove it now.
    staticMeshMgr.tryRemove(roadName)                                                               -- If any static mesh was created for this road on finalise, remove them now.
    local tunnels = road.tunnels
    local numTunnels = #tunnels
    for j = 1, numTunnels do                                                                        -- If any tunnel meshes were created, remove them now.
      local t = tunnels[j]
      tMesh.tryRemove(t.name)
      recoverHolemap(t.holes)
      table.clear(t.holes)
    end
    setDirty(road)
  end
  be:reloadCollision()                                                                              -- Re-load the collision mesh now that the meshes have been removed.
  map.reset({})                                                                                     -- Clear the navgraph.
end

-- Serialises a node.
local function serialiseNode(n)
  local widths, heightsL, heightsR = n.widths, n.heightsL, n.heightsR                               -- Serialise the widths/heights structures first.
  local serWidths, serHeightsL, serHeightsR = {}, {}, {}
  for i = -20, 20 do
    local w = widths[i]
    if w then
      serWidths[i], serHeightsL[i], serHeightsR[i] = w[0], heightsL[i][0], heightsR[i][0]
    end
  end
  local p = n.p
  return {                                                                                          -- Now serialise the node container.
    posX = p.x, posY = p.y, posZ = p.z,
    isLocked = n.isLocked,
    rot = n.rot[0],
    widths = serWidths, heightsL = serHeightsL, heightsR = serHeightsR,
    incircleRad = n.incircleRad[0],
    offset = n.offset }
end

-- Deserialises a node.
local function deserialiseNode(nSer)
  local serWidths, serHeightsL, serHeightsR = nSer.widths, nSer.heightsL, nSer.heightsR             -- De-serialise the widths/heights structures first.
  local widths, heightsL, heightsR = {}, {}, {}
  for i = -20, 20 do
    local w = serWidths[i]
    if w then
      widths[i] = im.FloatPtr(w)
      heightsL[i], heightsR[i] = im.FloatPtr(serHeightsL[i]), im.FloatPtr(serHeightsR[i])
    end
  end
  return {                                                                                          -- Now de-serialise the node container.
    p = vec3(nSer.posX, nSer.posY, nSer.posZ),
    isLocked = nSer.isLocked or false,
    rot = im.FloatPtr(nSer.rot),
    widths = widths, heightsL = heightsL, heightsR = heightsR,
    incircleRad = im.FloatPtr(nSer.incircleRad or 0.0),
    offset = nSer.offset or 0.0 }
end

-- Serializes a road.
local function serialiseRoad(r)
  local serNodes, nodes = {}, r.nodes
  local numNodes = #nodes
  for i = 1, numNodes do
    serNodes[i] = serialiseNode(nodes[i])
  end
  local w1, w2, hL1, hL2, hR1, hR2 = {}, {}, {}, {}, {}, {}
  for i = -20, 20 do
    if r.w1 and r.w1[i] then
      w1[i], hL1[i], hR1[i] = r.w1[i][0], r.hL1[i][0], r.hR1[i][0]
    end
    if r.w2 and r.w2[i] then
      w2[i], hL2[i], hR2[i] = r.w2[i][0], r.hL2[i][0], r.hR2[i][0]
    end
  end
  return {
    isHidden = r.isHidden,
    isMesh = r.isMesh,
    isLinkRoad = r.isLinkRoad,
    isDowelS = r.isDowelS or false, isDowelE = r.isDowelE or false,
    isArc = r.isArc or false,
    startR = r.startR, startLie = r.startLie, endR = r.endR, endLie = r.endLie,
    l1 = r.l1, l2 = r.l2,
    idxL0a_1 = r.idxL0a_1, idxL0a_2 = r.idxL0a_2, idxL0a_l2 = r.idxL0a_l2, idxL0a_l = r.idxL0a_l,
    idxL0b_1 = r.idxL0b_1, idxL0b_2 = r.idxL0b_2, idxL0b_l2 = r.idxL0b_l2, idxL0b_l = r.idxL0b_l,
    idxR0a_1 = r.idxR0a_1, idxR0a_2 = r.idxR0a_2, idxR0a_l2 = r.idxR0a_l2, idxR0a_l = r.idxR0a_l,
    idxR0b_1 = r.idxR0b_1, idxR0b_2 = r.idxR0b_2, idxR0b_l2 = r.idxR0b_l2, idxR0b_l = r.idxR0b_l,
    idxL1 = r.idxL1, idxL2 = r.idxL2, idxR1 = r.idxR1, idxR2 = r.idxR2,
    w1 = w1, w2 = w2,
    hL1 = hL1, hL2 = hL2, hR1 = hR1, hR2 = hR2,
    rot1 = r.rot1, rot2 = r.rot2,
    isLinkedToS = r.isLinkedToS, isLinkedToE = r.isLinkedToE,
    name = r.name,
    nodes = serNodes,
    profile = profileMgr.serialiseProfile(r.profile),
    targetLonRes = r.targetLonRes[0],
    targetArcRes = r.targetArcRes[0],
    isConformRoadToTerrain = r.isConformRoadToTerrain[0] or false,
    isDisplayRoadSurface = r.isDisplayRoadSurface[0],
    isDisplayRoadOutline = r.isDisplayRoadOutline[0],
    isDisplayNodeSpheres = r.isDisplayNodeSpheres[0],
    isDisplayNodeNumbers = r.isDisplayNodeNumbers[0],
    isDisplayRefLine = r.isDisplayRefLine[0],
    isAllowTunnels = r.isAllowTunnels[0],
    isRefLineDecal = r.isRefLineDecal[0],
    isEdgeLineDecal = r.isEdgeLineDecal[0],
    isLaneDivsDecal = r.isLaneDivsDecal[0],
    isStartLineDecal = r.isStartLineDecal[0],
    isEndLineDecal = r.isEndLineDecal[0],
    edgeDecalDist = r.edgeDecalDist[0],
    edgeDecalWidth = r.edgeDecalWidth[0],
    centerlineWidth = r.centerlineWidth[0],
    laneMarkingWidth = r.laneMarkingWidth[0],
    jctLineWidth = r.jctLineWidth[0],
    jctLineOffset = r.jctLineOffset[0],
    isDisplayLaneInfo = r.isDisplayLaneInfo[0],
    isRigidTranslation = r.isRigidTranslation[0],
    forceField = r.forceField[0],
    isCivilEngRoads = r.isCivilEngRoads[0],

    radGran = r.radGran[0],
    radOffset = r.radOffset[0],
    thickness = r.thickness[0],
    zOffsetFromRoad = r.zOffsetFromRoad[0],
    protrudeS = r.protrudeS[0],
    protrudeE = r.protrudeE[0],
    extraS = r.extraS[0],
    extraE = r.extraE[0],

    lampPostLonSpacing = r.lampPostLonSpacing[0],
    lampJitter = r.lampJitter[0],
    lampPostLonOffset = r.lampPostLonOffset[0],
    lampPostVertOffset = r.lampPostVertOffset[0],

    crashPostLonOffset = r.crashPostLonOffset[0],
    crashVertOffset = r.crashVertOffset[0],
    useDoublePlate = r.useDoublePlate[0],

    barrierLonOffset = r.barrierLonOffset[0],
    barrierVertOffset = r.barrierVertOffset[0],

    fenceLonOffset = r.fenceLonOffset[0],
    fenceVertOffset = r.fenceVertOffset[0],

    bollardLonSpacing= r.bollardLonSpacing[0],
    bollardJitter = r.bollardJitter[0],
    bollardLonOffset = r.bollardLonOffset[0],
    bollardVertOffset = r.bollardVertOffset[0] }
end

-- Deserializes a road.
local function deserialiseRoad(rSer)
  local nodes, serNodes = {}, rSer.nodes
  local numNodes = #serNodes
  for i = 1, numNodes do
    nodes[i] = deserialiseNode(serNodes[i])
  end
  local w1, w2, hL1, hL2, hR1, hR2 = {}, {}, {}, {}, {}, {}
  for i = -20, 20 do
    if rSer.w1 and rSer.w1[i] then
      w1[i], hL1[i], hR1[i] = im.FloatPtr(rSer.w1[i]), im.FloatPtr(rSer.hL1[i]), im.FloatPtr(rSer.hR1[i])
    end
    if rSer.w2 and rSer.w2[i] then
      w2[i], hL2[i], hR2[i] = im.FloatPtr(rSer.w2[i]), im.FloatPtr(rSer.hL2[i]), im.FloatPtr(rSer.hR2[i])
    end
  end
  local profile = profileMgr.deserialiseProfile(rSer.profile)
  local laneKeys, leftKeys, rightKeys = profileMgr.computeLaneKeys(profile)
  return {
    isDirty = true,
    isHidden = rSer.isHidden,
    isMesh = rSer.isMesh,
    isLinkRoad = rSer.isLinkRoad,
    isDowelS = rSer.isDowelS or false, isDowelE = rSer.isDowelE or false,
    isArc = rSer.isArc or false,
    renderData = nil,
    laneKeys = laneKeys, leftKeys = leftKeys, rightKeys = rightKeys,
    startR = rSer.startR, startLie = rSer.startLie, endR = rSer.endR, endLie = rSer.endLie,
    l1 = rSer.l1, l2 = rSer.l2,
    idxL0a_1 = rSer.idxL0a_1, idxL0a_2 = rSer.idxL0a_2, idxL0a_l2 = rSer.idxL0a_l2, idxL0a_l = rSer.idxL0a_l,
    idxL0b_1 = rSer.idxL0b_1, idxL0b_2 = rSer.idxL0b_2, idxL0b_l2 = rSer.idxL0b_l2, idxL0b_l = rSer.idxL0b_l,
    idxR0a_1 = rSer.idxR0a_1, idxR0a_2 = rSer.idxR0a_2, idxR0a_l2 = rSer.idxR0a_l2, idxR0a_l = rSer.idxR0a_l,
    idxR0b_1 = rSer.idxR0b_1, idxR0b_2 = rSer.idxR0b_2, idxR0b_l2 = rSer.idxR0b_l2, idxR0b_l = rSer.idxR0b_l,
    idxL1 = rSer.idxL1, idxL2 = rSer.idxL2, idxR1 = rSer.idxR1, idxR2 = rSer.idxR2,
    w1 = w1, w2 = w2,
    hL1 = hL1, hL2 = hL2, hR1 = hR1, hR2 = hR2,
    rot1 = rSer.rot1, rot2 = rSer.rot2,
    isLinkedToS = rSer.isLinkedToS, isLinkedToE = rSer.isLinkedToE,
    name = rSer.name,
    nodes = nodes,
    tunnels = {},
    profile = profile,
    targetLonRes = im.FloatPtr(rSer.targetLonRes or 5),
    targetArcRes = im.FloatPtr(rSer.targetArcRes or 5),
    isConformRoadToTerrain = im.BoolPtr(rSer.isConformRoadToTerrain),
    isDisplayRoadSurface = im.BoolPtr(rSer.isDisplayRoadSurface),
    isDisplayRoadOutline = im.BoolPtr(rSer.isDisplayRoadOutline),
    isDisplayNodeSpheres = im.BoolPtr(rSer.isDisplayNodeSpheres),
    isDisplayNodeNumbers = im.BoolPtr(rSer.isDisplayNodeNumbers),
    isDisplayRefLine = im.BoolPtr(rSer.isDisplayRefLine),
    isAllowTunnels = im.BoolPtr(rSer.isAllowTunnels),
    isRefLineDecal = im.BoolPtr(rSer.isRefLineDecal),
    isEdgeLineDecal = im.BoolPtr(rSer.isEdgeLineDecal),
    isLaneDivsDecal = im.BoolPtr(rSer.isLaneDivsDecal),
    isStartLineDecal = im.BoolPtr(rSer.isStartLineDecal),
    isEndLineDecal = im.BoolPtr(rSer.isEndLineDecal),
    edgeDecalDist = im.FloatPtr(rSer.edgeDecalDist or 0.11),
    edgeDecalWidth = im.FloatPtr(rSer.edgeDecalWidth or 0.1),
    centerlineWidth = im.FloatPtr(rSer.centerlineWidth or 0.1),
    laneMarkingWidth = im.FloatPtr(rSer.laneMarkingWidth or 0.1),
    jctLineWidth = im.FloatPtr(rSer.jctLineWidth or 0.1),
    jctLineOffset = im.FloatPtr(rSer.jctLineOffset or 0.0),
    isDisplayLaneInfo = im.BoolPtr(rSer.isDisplayLaneInfo),
    isRigidTranslation = im.BoolPtr(rSer.isRigidTranslation),
    forceField = im.FloatPtr(rSer.forceField or 0.1),
    isCivilEngRoads = im.BoolPtr(rSer.isCivilEngRoads),
    radGran = im.IntPtr(rSer.radGran or 15),
    radOffset = im.FloatPtr(rSer.radOffset or 0.0),
    thickness = im.FloatPtr(rSer.thickness or 1.0),
    zOffsetFromRoad = im.FloatPtr(rSer.zOffsetFromRoad or 0.0),
    protrudeS = im.FloatPtr(rSer.protrudeS or 0.0),
    protrudeE = im.FloatPtr(rSer.protrudeE or 0.0),
    extraS = im.IntPtr(rSer.extraS or 2),
    extraE = im.IntPtr(rSer.extraE or 2),

    lampPostLonSpacing = im.FloatPtr(rSer.lampPostLonSpacing or 10.0),
    lampJitter = im.FloatPtr(rSer.lampJitter or 0.0),
    lampPostLonOffset = im.FloatPtr(rSer.lampPostLonOffset or 0.0),
    lampPostVertOffset = im.FloatPtr(rSer.lampPostVertOffset or 1.0),

    crashPostLonOffset = im.FloatPtr(rSer.crashPostLonOffset or 0.0),
    crashVertOffset = im.FloatPtr(rSer.crashVertOffset or 0.0),
    useDoublePlate = im.BoolPtr(rSer.useDoublePlate),

    barrierLonOffset = im.FloatPtr(rSer.barrierLonOffset or 0.0),
    barrierVertOffset = im.FloatPtr(rSer.barrierVertOffset or 0.0),

    fenceLonOffset = im.FloatPtr(rSer.fenceLonOffset or 0.0),
    fenceVertOffset = im.FloatPtr(rSer.fenceVertOffset or 0.1),

    bollardLonSpacing = im.FloatPtr(rSer.bollardLonSpacing or 10.0),
    bollardJitter = im.FloatPtr(rSer.bollardJitter or 0.0),
    bollardLonOffset = im.FloatPtr(rSer.bollardLonOffset or 0.0),
    bollardVertOffset = im.FloatPtr(rSer.bollardVertOffset or 0.0) }
end


-- Public interface.
M.roads =                                                 roads
M.map =                                                   roadMap
M.multi =                                                 multi

M.isAuditionProfileDirty =                                isAuditionProfileDirty
M.isPOline =                                              isPOline
M.isPLane =                                               isPLane
M.createRoadFromProfile =                                 createRoadFromProfile
M.createRoadFromTemplate =                                createRoadFromTemplate
M.setDirty =                                              setDirty
M.setAuditionProfileDirty =                               setAuditionProfileDirty
M.addNodeToRoad =                                         addNodeToRoad
M.copyNode =                                              copyNode
M.updateWAndHToNewProfile =                               updateWAndHToNewProfile
M.computeAABB2D =                                         computeAABB2D
M.computeAABB2DAllRoads =                                 computeAABB2DAllRoads
M.offsetRoads2Terrain =                                   offsetRoads2Terrain
M.offsetByValue =                                         offsetByValue
M.recomputeMap =                                          recomputeMap
M.removeRoad =                                            removeRoad
M.removeNode =                                            removeNode
M.addIntermediateNode =                                   addIntermediateNode
M.clearAllRoads =                                         clearAllRoads
M.setAllMesh =                                            setAllMesh
M.setAllDecals =                                          setAllDecals
M.removeHiddenRoads =                                     removeHiddenRoads
M.goToRoad =                                              goToRoad
M.moveRoad =                                              moveRoad
M.adjustHeight =                                          adjustHeight
M.adjustLateralRotation =                                 adjustLateralRotation
M.unlinkStart =                                           unlinkStart
M.unlinkEnd =                                             unlinkEnd
M.copyRoad =                                              copyRoad
M.splitRoad =                                             splitRoad
M.flipRoad =                                              flipRoad
M.updateRoads =                                           updateRoads
M.removeAll =                                             removeAll
M.manageTempRoadSection =                                 manageTempRoadSection
M.createMultiSelect =                                     createMultiSelect
M.bulldoze =                                              bulldoze
M.finalise =                                              finalise
M.unfinalise =                                            unfinalise
M.computeAllRoadRenderData =                              computeAllRoadRenderData
M.serialiseRoad =                                         serialiseRoad
M.deserialiseRoad =                                       deserialiseRoad

return M