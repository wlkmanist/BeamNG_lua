-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local layers = require("ui/apps/minimap/layers")

-- Configuration
local HEIGHTMAP_RESOLUTION = 5 -- meters between height samples

-- State variables
local topoMapLoaded = false
local heightmapData = {}
local heightmapBounds = {minX = 0, maxX = 0, minY = 0, maxY = 0}
local heightmapResolution = HEIGHTMAP_RESOLUTION

-- Contour lines spatial structure
local quadtree = require('kdtreebox2d')
local contourQt = nil
local contourSegments = {}

-- Marching squares algorithm for contour generation
local function marchingSquares(d, ilb, iub, jlb, jub, x, y, nc, z, contourLevels)
  log("I", "", string.format("Marching squares: grid %dx%d, levels: %d", iub-ilb, jub-jlb, nc))
  log("I", "", string.format("X range: %.1f to %.1f", x[ilb], x[iub]))
  log("I", "", string.format("Y range: %.1f to %.1f", y[jlb], y[jub]))

  for levelIndex = 1, nc do
    local zc = contourLevels[levelIndex]
    log("I", "", string.format("Processing contour level: %.1f", zc))

    for i = ilb, iub - 1 do
      for j = jlb, jub - 1 do
        -- Get the four corners of the cell
        local d00 = d[i][j] or 0
        local d10 = d[i+1][j] or 0
        local d11 = d[i+1][j+1] or 0
        local d01 = d[i][j+1] or 0

        -- Debug: log some sample values
        if i == ilb and j == jlb then
          log("I", "", string.format("Sample cell [%d,%d]: heights %.1f,%.1f,%.1f,%.1f", i, j, d00, d10, d11, d01))
        end

        -- Calculate cell case (0-15)
        local caseIndex = 0
        if d00 >= zc then caseIndex = caseIndex + 1 end
        if d10 >= zc then caseIndex = caseIndex + 2 end
        if d11 >= zc then caseIndex = caseIndex + 4 end
        if d01 >= zc then caseIndex = caseIndex + 8 end

        -- Skip if no intersection or all above/below
        if caseIndex == 0 or caseIndex == 15 then
          goto continue
        end

        local points = {}

        -- Check each edge for intersection
        -- Bottom edge (i,j) to (i+1,j)
        if (d00 >= zc) ~= (d10 >= zc) then
          local t = (zc - d00) / (d10 - d00)
          local xc = x[i] + t * (x[i+1] - x[i])
          local yc = y[j]
          table.insert(points, {x = xc, y = yc})
          if i == ilb and j == jlb then
            log("I", "", string.format("Bottom edge intersection: t=%.3f, pos=(%.1f,%.1f)", t, xc, yc))
          end
        end

        -- Right edge (i+1,j) to (i+1,j+1)
        if (d10 >= zc) ~= (d11 >= zc) then
          local t = (zc - d10) / (d11 - d10)
          local xc = x[i+1]
          local yc = y[j] + t * (y[j+1] - y[j])
          table.insert(points, {x = xc, y = yc})
          if i == ilb and j == jlb then
            log("I", "", string.format("Right edge intersection: t=%.3f, pos=(%.1f,%.1f)", t, xc, yc))
          end
        end

        -- Top edge (i,j+1) to (i+1,j+1)
        if (d01 >= zc) ~= (d11 >= zc) then
          local t = (zc - d01) / (d11 - d01)
          local xc = x[i] + t * (x[i+1] - x[i])
          local yc = y[j+1]
          table.insert(points, {x = xc, y = yc})
          if i == ilb and j == jlb then
            log("I", "", string.format("Top edge intersection: t=%.3f, pos=(%.1f,%.1f)", t, xc, yc))
          end
        end

        -- Left edge (i,j) to (i,j+1)
        if (d00 >= zc) ~= (d01 >= zc) then
          local t = (zc - d00) / (d01 - d00)
          local xc = x[i]
          local yc = y[j] + t * (y[j+1] - y[j])
          table.insert(points, {x = xc, y = yc})
          if i == ilb and j == jlb then
            log("I", "", string.format("Left edge intersection: t=%.3f, pos=(%.1f,%.1f)", t, xc, yc))
          end
        end

                        -- Create line segment from the two points
        if #points >= 2 then
          local segment = {zc, points[1].x, points[1].y, points[2].x, points[2].y}
          table.insert(contourSegments, segment)
          if i == ilb and j == jlb then
            log("I", "", string.format("Created segment: level %.1f, (%.1f,%.1f) to (%.1f,%.1f)",
              zc, points[1].x, points[1].y, points[2].x, points[2].y))
          end

          -- Debug: log first few segments to see what's being created
          if #contourSegments <= 5 then
            log("I", "", string.format("Segment %d: level %.1f, (%.1f,%.1f) to (%.1f,%.1f)",
              #contourSegments, zc, points[1].x, points[1].y, points[2].x, points[2].y))
          end
        end

        ::continue::
      end
    end
  end
end

-- Helper function to calculate navgraph bounds
local function calculateNavgraphBounds()
  local mapData = map.getMap()
  if not mapData or not mapData.nodes then
    log("E", "", "Failed to get map data for topo map bounds calculation")
    return false
  end

  local minX, maxX = math.huge, -math.huge
  local minY, maxY = math.huge, -math.huge

  -- Find bounds from all navgraph nodes
  for nodeId, node in pairs(mapData.nodes) do
    if node.pos then
      minX = math.min(minX, node.pos.x)
      maxX = math.max(maxX, node.pos.x)
      minY = math.min(minY, node.pos.y)
      maxY = math.max(maxY, node.pos.y)
    end
  end

  -- Check if we found valid bounds
  if minX == math.huge or maxX == -math.huge then
    log("E", "", "No valid navgraph nodes found for topo map bounds")
    return false
  end

    -- Use navgraph bounds but ensure we're within reasonable terrain area
  local expansion = 100
  local terrainRadius = 2000 -- Reasonable terrain radius

  -- If navgraph is very spread out, focus on a reasonable area around origin
  if math.abs(maxX - minX) > terrainRadius * 2 or math.abs(maxY - minY) > terrainRadius * 2 then
    log("I", "", "Navgraph very spread out, focusing on terrain area around origin")
    heightmapBounds.minX = -terrainRadius
    heightmapBounds.maxX = terrainRadius
    heightmapBounds.minY = -terrainRadius
    heightmapBounds.maxY = terrainRadius
  else
    -- Expand bounds by 100 units, but clamp to reasonable terrain area
    heightmapBounds.minX = math.max(minX - expansion, -terrainRadius)
    heightmapBounds.maxX = math.min(maxX + expansion, terrainRadius)
    heightmapBounds.minY = math.max(minY - expansion, -terrainRadius)
    heightmapBounds.maxY = math.min(maxY + expansion, terrainRadius)
  end

  log("I", "", string.format("Topo map bounds: X[%.1f, %.1f], Y[%.1f, %.1f]",
    heightmapBounds.minX, heightmapBounds.maxX, heightmapBounds.minY, heightmapBounds.maxY))

  return true
end

-- Helper function to scan terrain height
local function scanTerrainHeight()
  if not heightmapBounds.minX or not heightmapBounds.maxX then
    log("E", "", "Heightmap bounds not calculated, cannot scan terrain")
    return false
  end

  -- Calculate grid dimensions
  local width = heightmapBounds.maxX - heightmapBounds.minX
  local height = heightmapBounds.maxY - heightmapBounds.minY
  local gridWidth = math.ceil(width / heightmapResolution)
  local gridHeight = math.ceil(height / heightmapResolution)

    log("I", "", string.format("Scanning terrain heightmap: %dx%d grid (%.1fm resolution)",
    gridWidth, gridHeight, heightmapResolution))

  -- Test terrain height at origin and nearby points
  log("I", "", string.format("Test heights: origin=%.1f, (100,0)=%.1f, (0,100)=%.1f",
    core_terrain.getTerrainHeight(vec3(0,0,0)) or 0,
    core_terrain.getTerrainHeight(vec3(100,0,0)) or 0,
    core_terrain.getTerrainHeight(vec3(0,100,0)) or 0))

  -- Initialize heightmap data structure
  heightmapData = {
    bounds = heightmapBounds,
    resolution = heightmapResolution,
    gridWidth = gridWidth,
    gridHeight = gridHeight,
    data = {}
  }

  -- Scan terrain height at each grid point
  local scanPos = vec3()
  local terrain = core_terrain.getTerrain()

  if not terrain then
    log("E", "", "No terrain available for heightmap scanning")
    return false
  end

  for x = 0, gridWidth do
    heightmapData.data[x] = {}
    for y = 0, gridHeight do
      -- Calculate world position for this grid point
      scanPos.x = heightmapBounds.minX + (x * heightmapResolution)
      scanPos.y = heightmapBounds.minY + (y * heightmapResolution)
      scanPos.z = 0

      -- Get terrain height at this position
      local terrainHeight = core_terrain.getTerrainHeight(scanPos)
      if terrainHeight and terrainHeight > 0 then
        heightmapData.data[x][y] = terrainHeight
      else
        heightmapData.data[x][y] = 0
      end

      -- Debug: log some sample heights
      if x <= 2 and y <= 2 then
        log("I", "", string.format("Height at [%d,%d] (%.1f,%.1f): %.1f", x, y, scanPos.x, scanPos.y, terrainHeight or 0))
      end
    end
  end

  log("I", "", string.format("Terrain heightmap scan complete: %dx%d samples", gridWidth + 1, gridHeight + 1))
  return true
end

-- Helper function to generate contour lines from heightmap
local function generateContourLines()
  if not heightmapData.data or not heightmapData.gridWidth or not heightmapData.gridHeight then
    log("E", "", "Heightmap data not available for contour generation")
    return false
  end

  log("I", "", "Generating contour lines from heightmap...")

  -- Find min/max heights for contour levels
  local minHeight, maxHeight = math.huge, -math.huge
  for x = 0, heightmapData.gridWidth do
    for y = 0, heightmapData.gridHeight do
      local h = heightmapData.data[x][y]
      if h > 0 then
        minHeight = math.min(minHeight, h)
        maxHeight = math.max(maxHeight, h)
      end
    end
  end

  if minHeight == math.huge then
    log("E", "", "No valid height data found for contour generation")
    return false
  end

  -- Generate contour levels (every 10 meters for now)
  local contourLevels = {}
  local levelStep = 2.5
  for level = math.floor(minHeight / levelStep) * levelStep, maxHeight, levelStep do
    if level >= minHeight and level <= maxHeight then
      table.insert(contourLevels, level)
    end
  end

  log("I", "", string.format("Generating contours from %.1f to %.1f (step %.1f)", minHeight, maxHeight, levelStep))

    -- Prepare data for marching squares algorithm
  local d = {}
  local x = {}
  local y = {}

  log("I", "", string.format("Preparing data: grid %dx%d, bounds (%.1f,%.1f) to (%.1f,%.1f)",
    heightmapData.gridWidth, heightmapData.gridHeight,
    heightmapBounds.minX, heightmapBounds.minY, heightmapBounds.maxX, heightmapBounds.maxY))

  for i = 0, heightmapData.gridWidth do
    d[i] = {}
    x[i] = heightmapBounds.minX + (i * heightmapResolution)
    for j = 0, heightmapData.gridHeight do
      d[i][j] = heightmapData.data[i][j] or 0
      if i == 0 then
        y[j] = heightmapBounds.minY + (j * heightmapResolution)
      end
    end
  end

  -- Debug: log some sample data
  log("I", "", string.format("Sample X coords: %.1f, %.1f, %.1f", x[0], x[1], x[2]))
  log("I", "", string.format("Sample Y coords: %.1f, %.1f, %.1f", y[0], y[1], y[2]))
  log("I", "", string.format("Sample heights: %.1f, %.1f, %.1f", d[0][0], d[1][0], d[0][1]))

  -- Check for non-zero heights
  local nonZeroCount = 0
  local maxHeight = 0
  for i = 0, heightmapData.gridWidth do
    for j = 0, heightmapData.gridHeight do
      if d[i][j] and d[i][j] > 0 then
        nonZeroCount = nonZeroCount + 1
        maxHeight = math.max(maxHeight, d[i][j])
      end
    end
  end
  log("I", "", string.format("Non-zero heights: %d/%d, max height: %.1f",
    nonZeroCount, (heightmapData.gridWidth + 1) * (heightmapData.gridHeight + 1), maxHeight))

  -- Clear previous contour data
  contourSegments = {}

  -- Run marching squares algorithm
  marchingSquares(d, 0, heightmapData.gridWidth, 0, heightmapData.gridHeight, x, y, #contourLevels, nil, contourLevels)

  log("I", "", string.format("Generated %d contour segments", #contourSegments))

  -- Build spatial structure for contour segments
  if #contourSegments > 0 then
    contourQt = quadtree.new()
    local segIdx = 1

        for i, segment in ipairs(contourSegments) do
      -- Calculate bounding box for this segment
      local level, x1, y1, x2, y2 = segment[1], segment[2], segment[3], segment[4], segment[5]
      local minX = math.min(x1, x2)
      local maxX = math.max(x1, x2)
      local minY = math.min(y1, y2)
      local maxY = math.max(y1, y2)

      -- Add some padding for better spatial queries
      local padding = 1.0
      contourQt:preLoad(segIdx, minX - padding, minY - padding, maxX + padding, maxY + padding)
      segIdx = segIdx + 1
    end

    contourQt:build()
    log("I", "", "Contour spatial structure built")
  end

  return true
end

-- Main function to load the topo map
local function loadTopoMap()
  if topoMapLoaded then
    return true
  end

  log("I", "", "Loading topo map...")

  -- Step 1: Calculate navgraph bounds
  if not calculateNavgraphBounds() then
    return false
  end

  -- Step 2: Scan terrain height
  if not scanTerrainHeight() then
    return false
  end

  -- Step 3: Generate contour lines
  if not generateContourLines() then
    return false
  end

  topoMapLoaded = true
  log("I", "", "Topo map loaded successfully")
  return true
end

local p1, p2 = vec3(), vec3()
M.drawContours = function(td, width, height, scale, camPos, worldToMapXYZ)
  local contourSegments = ui_apps_sdfTopomap.getContourSegments()
  local contourQt = ui_apps_sdfTopomap.getContourQuadtree()
  local radius = 200 * scale
  local count = 0
  for i in contourQt:queryNotNested(camPos.x-radius, camPos.y-radius, camPos.x+radius, camPos.y+radius) do
    --local p1, p2 = vec3(), vec3()
  --for i = 1, #contourSegments do
    local segment = contourSegments[i]
    local level = segment[1]
    p1:set(segment[2], segment[3], 0)
    p2:set(segment[4], segment[5], 0)
    worldToMapXYZ(p1, p1)
    worldToMapXYZ(p2, p2)
    -- level goes from 0 to 100
    local clr = color(128 + level*1.25, 128 + level*1.25, 128 + level*1.25, 255)
    local thickness = 1 + (level%10 == 0 and 0.5 or 0)
    td:lineRoundEnd(p1.x, p1.y, p2.x, p2.y, thickness, thickness, 0, clr, clr, clr, clr, 0, layers.BACKGROUND)
    count = count + 1
    if count > 5000 then break end
  end
end

-- Public API
M.loadTopoMap = loadTopoMap
M.isLoaded = function() return topoMapLoaded end
M.getHeightmapData = function() return heightmapData end
M.getHeightmapBounds = function() return heightmapBounds end
M.getContourSegments = function() return contourSegments end
M.getContourQuadtree = function() return contourQt end

-- Reset function for mission changes
M.onClientEndMission = function()
  topoMapLoaded = false
  heightmapData = {}
  heightmapBounds = {minX = 0, maxX = 0, minY = 0, maxY = 0}
  contourSegments = {}
  contourQt = nil
end

M.onClientStartMission = function()
  topoMapLoaded = false
  heightmapData = {}
  heightmapBounds = {minX = 0, maxX = 0, minY = 0, maxY = 0}
  contourSegments = {}
  contourQt = nil
end

return M