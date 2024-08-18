-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Module constants.
local maxRayDist = 1000                                                                             -- The maximum distance for the camera->mouse ray, in metres.
local laneWidthTol = 1e-3                                                                           -- A tolerance used when determining if a lane width is zero, or not.
local mouseToNodetol = 0.84                                                                         -- The distance tolerance used when testing if the mouse is close to a node.
local mouseToNodetol2 = 0.15                                                                        -- The distance tolerance used when testing if the mouse is close to a lane end.
local sphereColor = color(255, 0, 0, 127)                                                           -- The colour used for drawing red spheres.
local groupSphereColor = color(255, 0, 255, 127)                                                    -- The colour used for drawing group polygon spheres.
local highlightColor = color(127, 127, 127, 127)                                                    -- The colour used for drawing transparent highlights.
local highlightMargin = 0.2                                                                         -- The margin by which a highlight surrounds an object (multip. factor).

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}


-- External modules used.
local dbgDraw = require('utils/debugDraw')


-- Private constants.
local im = ui_imgui
local min, max, sqrt = math.min, math.max, math.sqrt


-- Draws spheres (for various purposes).
-- [The size of the sphere varies with the camera distance, so as to keep the sphere about the same size].
local function drawSphere(pos) dbgDraw.drawSphere(pos, sqrt(pos:distance(core_camera.getPosition())) * 0.1, sphereColor) end
local function drawGroupSphere(pos) dbgDraw.drawSphere(pos, sqrt(pos:distance(core_camera.getPosition())) * 0.1, groupSphereColor) end
local function drawSphereHighlight(pos) dbgDraw.drawSphere(pos, sqrt(pos:distance(core_camera.getPosition())) * highlightMargin, highlightColor) end

-- Tests if mouse is hovering over the terrain (as opposed to any windows, etc).
local function isMouseHoveringOverTerrain() return not im.IsAnyItemHovered() and not im.IsWindowHovered(im.HoveredFlags_AnyWindow) and not editor.isAxisGizmoHovered() end

-- Tests if the mouse has been clicked on the terrain.
local function didMouseClickOnTerrain() return im.IsMouseClicked(0) end

-- Computes the position on the map at which the mouse points.
local function mouseOnMapPos()
  local ray = getCameraMouseRay()
  local rayPos, rayDir = ray.pos, ray.dir
  return rayPos + rayDir * castRayStatic(rayPos, rayDir, 1000)
end

-- Checks if the mouse is hovering over any existing reference node. If so, returns the relevant data.
-- [The road and node indices are returned].
local function isMouseOverNode(roads)
  local ray = getCameraMouseRay()
  local rayPos, rayDir = ray.pos, ray.dir
  local numRoads = #roads
  for i = 1, numRoads do
    local r = roads[i]
    if r.isDisplayNodeSpheres[0] then                                                               -- Only consider a road if the node spheres are currently visible.
      local nodes = r.nodes
      local numNodes = #nodes
      for j = 1, numNodes do
        local node = nodes[j]
        if not r.isLinkRoad and not node.isLocked then                                              -- Do not consider link road nodes or locked nodes.
          local a, b = intersectsRay_Sphere(rayPos, rayDir, node.p, mouseToNodetol)                 -- Get the two intersection points between the ray and sphere, if any exist.
          if min(a, b) < maxRayDist then                                                            -- If they do exist, the mouse is over this node, so we have found target.
            return true, i, j                                                                       -- Return the road and node indices, along with the relevant flag combo.
          end
        end
      end
    end
  end
  return nil, nil, nil                                                                              -- The mouse is not over any node of any road, so return nil.
end

-- Checks if the mouse is hovering over any existing lane endpoint node. If so, returns the relevant data.
-- [Returns the road name/index and lane index, along with relevant flags].
local function isMouseOverLaneEnd(roads)

  local ray = getCameraMouseRay()
  local rayPos, rayDir = ray.pos, ray.dir
  local numRoads = #roads
  for i = 1, numRoads do
    local r = roads[i]
    local renderData, laneKeys = r.renderData, r.laneKeys
    if renderData and #renderData > 0 then
      local numDivs, numLaneKeys = #renderData, #laneKeys
      local divS, divE = renderData[1], renderData[numDivs]
      for k = 1, numLaneKeys do
        local laneId = laneKeys[k]
        local dSLane = divS[laneId]
        if dSLane[9] > laneWidthTol then                                                            -- Only display sphere if the lane width here is non-zero.
          local a, b = intersectsRay_Sphere(rayPos, rayDir, divS[laneId][7], mouseToNodetol2)       -- Test for an intersection with the lane start node sphere.
          if min(a, b) < maxRayDist then                                                            -- If they do exist, the mouse is over this node, so we have found target.
            return true, false, i, r.name, laneId                                                   -- Return the road and lane indices, along with the relevant flag combo.
          end
        end
        local dELane = divE[laneId]
        if dELane[9] > laneWidthTol then                                                            -- Only display sphere if the lane width here is non-zero.
          local a, b = intersectsRay_Sphere(rayPos, rayDir, divE[laneId][7], mouseToNodetol2)       -- Test for an intersection with the lane end node sphere.
          if min(a, b) < maxRayDist then                                                            -- If they do exist, the mouse is over this node, so we have found target.
            return false, true, i, r.name, laneId                                                   -- Return the road and lane index, along with the relevant flag combo.
          end
        end
      end
    end
  end
  return nil, nil, nil, nil, nil                                                                    -- The mouse is not over any lane-end of any road, so return nil.
end

-- Re-maps the lane width indices to those in the provided array.
local function reMapWAndH(widths, heightsL, heightsR, orderedLanes, minKey, numMatches)
  local wMapped, hLMapped, hRMapped, ctr = {}, {}, {}, 1
  for i = minKey, 10 do
    local laneWidth = widths[i]
    if laneWidth  and laneWidth[0] > 1e-03 then
      local lIdx = orderedLanes[ctr]
      wMapped[lIdx], hLMapped[lIdx], hRMapped[lIdx] = laneWidth, heightsL[i], heightsR[i]
      ctr = ctr + 1
      if ctr > numMatches then
        return wMapped, hLMapped, hRMapped
      end
    end
  end
  return wMapped, hLMapped, hRMapped
end

-- Flips the width and height (left and right) values from low to high, while keeping the keys.
local function flipWAndH(widths, heightsL, heightsR)
  local keys, valsW, valsHL, valsHR, ctr = {}, {}, {}, {}, 1
  for i = -20, 20 do
    local w, hL, hR = widths[i], heightsL[i], heightsR[i]
    if w then
      keys[ctr], valsW[ctr], valsHL[ctr], valsHR[ctr] = i, w[0], hL[0], hR[0]
      ctr = ctr + 1
    end
  end
  local outW, outHL, outHR, numKeys, ctr = {}, {}, {}, #keys, 1
  for i = numKeys, 1, -1 do
    local kC = keys[ctr]
    outW[kC], outHL[kC], outHR[kC] = im.FloatPtr(valsW[i]), im.FloatPtr(valsHR[i]), im.FloatPtr(valsHL[i])
    ctr = ctr + 1
  end
  return outW, outHL, outHR
end


-- Public interface.
M.drawSphere =                                            drawSphere
M.drawGroupSphere =                                       drawGroupSphere
M.drawSphereHighlight =                                   drawSphereHighlight
M.isMouseHoveringOverTerrain =                            isMouseHoveringOverTerrain
M.mouseOnMapPos =                                         mouseOnMapPos
M.isMouseOverNode =                                       isMouseOverNode
M.isMouseOverLaneEnd =                                    isMouseOverLaneEnd
M.reMapWAndH =                                            reMapWAndH
M.flipWAndH =                                             flipWAndH

return M