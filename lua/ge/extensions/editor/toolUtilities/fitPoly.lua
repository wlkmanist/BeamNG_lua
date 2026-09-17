-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This is a utility class for fitting a polyline to an unordered set of points.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local maxDist = 50.0 -- Maximum distance to consider two neighbouring points.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module constants.
local negativeHuge = -math.huge
local maxDistSq = maxDist * maxDist

-- Module state.
local toPoint, currentDir = vec3(), vec3()
local dir1, dir2 = vec3(), vec3()


-- Find the best next point considering both distance and direction.
local function findBestNextPoint(positions, current, visited)
  local bestPoint, bestScore = nil, -1
  for i = 1, #positions do
    if not visited[i] then
      local distSq = positions[i]:squaredDistance(positions[current])
      if distSq <= maxDistSq then
        local score = 1.0 / (distSq + 0.1) -- Base score (closer is better).
        if currentDir then -- If we have a current direction, prefer points that continue it.
          toPoint:setSub2(positions[i], positions[current])
          toPoint:normalize()
          local dot = currentDir:dot(toPoint)
          if dot > 0.5 then
            score = score * (1.0 + dot) -- Bonus for good direction.
          elseif dot < -0.5 then
            score = score * 0.1 -- Heavy penalty for reversal.
          else
            score = score * (0.5 + dot * 0.5) -- Moderate penalty for sharp turn.
          end
        end
        if score > bestScore then
          bestScore, bestPoint = score, i
        end
      end
    end
  end
  return bestPoint
end

-- Build a path starting from a given point
local function buildPathFromStart(positions, startPoint)
  -- Iterate through the points, starting from the given start point.
  local path, visited, current = {}, {}, startPoint
  while current do
    table.insert(path, current)
    visited[current] = true
    local nextPoint = findBestNextPoint(positions, current, visited) -- Find best next point.
    if nextPoint then
      currentDir:setSub2(positions[nextPoint], positions[current])
      currentDir:normalize()
      current = nextPoint
    else
      current = nil
    end
  end

  -- Add any remaining unvisited points.
  for i = 1, #positions do
    if not visited[i] then
      table.insert(path, i)
    end
  end

  return path
end

-- Evaluate the quality of a path (higher score = better path)
local function evaluatePath(positions, path)
  if #path < 2 then
    return 0 -- Return 0 if the path is too short.
  end

  -- Calculate smoothness (direction consistency).
  local smoothnessScore, distanceScore = 0, 0
  for i = 2, #path - 1 do
    -- Calculate direction consistency.
    local prev, curr, next = positions[path[i - 1]], positions[path[i]], positions[path[i + 1]]
    dir1:setSub2(curr, prev)
    dir1:normalize()
    dir2:setSub2(next, curr)
    dir2:normalize()
    local dot = dir1:dot(dir2)

    -- Penalise sharp turns and direction reversals.
    if dot < 0 then
      smoothnessScore = smoothnessScore - 2.0 -- Heavy penalty for reversals.
    elseif dot < 0.5 then
      smoothnessScore = smoothnessScore - (1.0 - dot) -- Penalty for sharp turns.
    else
      smoothnessScore = smoothnessScore + dot -- Reward for smooth continuation.
    end
  end

  -- Calculate total distance (shorter is better).
  for i = 2, #path do
    distanceScore = distanceScore + positions[path[i - 1]]:distance(positions[path[i]])
  end

  -- Combine scores (smoothness is more important).
  return smoothnessScore * 0.7 - distanceScore * 0.3
end

-- Fits a polyline to an unordered set of points.
local function fitPoly(components)
  if #components < 2 then
    return components -- Early return if there are less than two components.
  end

  -- Get the positions of the components.
  local positions = {}
  for i = 1, #components do
    positions[i] = components[i].obj:getPosition()
  end

  -- Try every single point as a starting point.
  local bestPath, bestScore = nil, negativeHuge
  for startPoint = 1, #positions do
    local path = buildPathFromStart(positions, startPoint)
    local score = evaluatePath(positions, path)
    if score > bestScore then
      bestScore, bestPath = score, path
    end
  end

  -- Convert best path indices to components.
  local result = {}
  for i = 1, #bestPath do
    result[i] = components[bestPath[i]]
  end

  return result
end


-- Public interface.
M.fitPoly =                                             fitPoly

return M


