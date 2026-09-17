-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this file,
-- You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local anchorPrefixStr = "sidewalk" -- The expected prefix for all tool-compatible anchor point names.
local variationFilenameStr = "var" -- The expected string to appear in variation filenames.
local rectMeshFileName = "square.dae" -- The expected filename for the rect sidewalk piece.
local pizzaMeshFileName = "triangle.dae" -- The expected filename for the pizza sidewalk piece.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}
local logtag = "sidewalkSpline.kit"

-- Module constants.
local anchorPrefixStrWithDot = anchorPrefixStr .. '.'

local tmpParts = {} -- Pre-allocated table for parsing anchor names.


-- Extracts sidewalk anchor points from a mesh.
local function getSidewalkAnchors(meshPath)
  -- Create a temporary mesh to read the anchor points from.
  local obj = createObject('TSStatic')
  obj.cansave = false
  obj:setField('shapeName', 0, meshPath)
  obj:registerObject('temp_parseAnchorPoints')

  -- Get all anchor point names from this mesh.
  local anchorNames = obj:getAnchorNames()

  -- Collect sidewalk anchor points.
  local anchors = {}
  for i = 1, #anchorNames do
    local anchorName = anchorNames[i]
    if anchorName:sub(1, 9) == anchorPrefixStrWithDot then
      table.clear(tmpParts) -- Clear the reusable table.
      for part in anchorName:gmatch("[^%.]+") do -- Parse the anchor point name into parts.
        tmpParts[#tmpParts + 1] = part
      end

      -- Validate against the sidewalk anchor point format: [sidewalk.leftA] or [sidewalk.rightB] etc.
      -- [1] = prefix "sidewalk", [2] = anchor identifier like "leftA", "rightA", "leftB", "rightB".
      if #tmpParts >= 2 and tmpParts[1] == anchorPrefixStr then
        local anchorId = tmpParts[2]
        local _, pos = obj:getNodeTransform(anchorName)
        anchors[anchorId] = vec3(pos)
      end
    end
  end

  obj:delete()

  return anchors
end

-- Gets the sidewalk kit from the given folder path.
local function getSidewalkKit(kitFolderPath)
  local sidewalkKit = {}
  if not kitFolderPath then
    return sidewalkKit -- Early return if no kit folder path.
  end
  local meshPaths = FS:findFiles(kitFolderPath, "*.dae", -1, true, false)
  for i = 1, #meshPaths do
    local meshPath = meshPaths[i]
    table.insert(sidewalkKit, {
      id = Engine.generateUUID(),
      meshPath = meshPath,
      fileName = string.match(meshPath, "([^/\\]+)$") or meshPath,
      folderPath = string.match(meshPath, "(.+)/[^/\\]+$") or "",
    })
  end
  return sidewalkKit
end

-- Pre-computes anchor vectors and piece data for a sidewalk kit.
local function buildSidewalkKit(meshKit, spline)
  if not meshKit or #meshKit == 0 then
    return nil -- Early return if no kit meshes.
  end

  -- Group variations with their base meshes.
  local baseToVariations = {}
  for i = 1, #meshKit do
    local mesh = meshKit[i]
    if mesh.fileName:lower():find(variationFilenameStr) then
      local baseName = mesh.fileName:match("(.+)_var") .. ".dae" -- Find the base mesh by taking everything before '_var' and adding '.dae'.
      baseToVariations[baseName] = baseToVariations[baseName] or {}
      table.insert(baseToVariations[baseName], mesh)
    end
  end

  -- Get the base meshes from the kit, excluding variations.
  local baseMeshes = {}
  for i = 1, #meshKit do
    local mesh = meshKit[i]
    if not mesh.fileName:lower():find(variationFilenameStr) then
      baseMeshes[#baseMeshes + 1] = mesh
    end
  end
  if #baseMeshes < 1 then
    return nil -- Early return if no base meshes.
  end

  -- Process each base mesh. Anchor points are optional for the new sidewalk system.
  local pieces = {}
  for i = 1, #baseMeshes do
    local mesh = baseMeshes[i]

    -- Extract anchor points (optional; not required by the new tiler).
    local anchors = getSidewalkAnchors(mesh.meshPath)

    -- Check if this piece is enabled in the spline (keyed by pieceIndex).
    local isEnabled = true
    if spline and spline.pieceEnabledStates and spline.pieceEnabledStates[i] ~= nil then
      isEnabled = spline.pieceEnabledStates[i]
    end

    -- Get distribution settings for this piece.
    local pieceDistribution = spline and spline.pieceDistribution and spline.pieceDistribution[i] or {}

    -- Create the piece data structure.
    local piece = {
      pieceIndex = i,
      baseMesh = mesh,
      anchors = anchors,
      startVec = nil,
      endVec = nil,
      length = 0.0,
      variations = baseToVariations[mesh.fileName] or {},
      isEnabled = isEnabled,
      isRandom = pieceDistribution.isRandom or false,
      baseWeight =  pieceDistribution.baseWeight or 1.0,
      varWeights = pieceDistribution.varWeights or {},
    }

    -- Add unique ids to the variations.
    local variations = piece.variations
    for j = 1, #variations do
      local variation = variations[j]
      variation.varId = mesh.id .. "_var" .. j
    end

    pieces[#pieces + 1] = piece
  end

  -- Create the sidewalk kit description.
  return {
    pieces = pieces,
    folderPath = meshKit[1] and meshKit[1].folderPath or "",
  }
end

-- Builds distribution groups (for efficient piece selection during population).
local function buildDistributionGroups(spline)
  local groups = {}
  local kitDescription = spline.kitDescription
  if not kitDescription or not kitDescription.pieces then
    return groups -- Early return if no kit description.
  end

  -- For each base piece, create groups with enabled base/variations.
  local states = spline.pieceEnabledStates or {}
  local pieces = kitDescription.pieces
  for i = 1, #pieces do
    local piece = pieces[i]
    local pieceIndex = piece.pieceIndex
    local baseEnabled = (states[pieceIndex] ~= false)

    -- Count enabled meshes in this piece family (base + variations).
    local enabledCount = 0
    if baseEnabled then
      enabledCount = enabledCount + 1
    end
    local variations = piece.variations
    for j = 1, #variations do
      local variation = variations[j]
      local varEnabled = (states[variation.varId] ~= false)
      if varEnabled then
        enabledCount = enabledCount + 1
      end
    end

    -- Create group if at least one mesh is enabled.
    if enabledCount > 0 then
      -- Get distribution settings for this piece.
      local pieceDistribution = spline.pieceDistribution and spline.pieceDistribution[pieceIndex] or {}
      local isRandom = pieceDistribution.isRandom or false
      local baseWeight = pieceDistribution.baseWeight or 1.0
      local varWeights = pieceDistribution.varWeights or {}

      local group = {
        entries = {},
        totalWeight = 0.0,
        counter = 1,
        isRandom = isRandom,
        piece = piece, -- Reference to the piece data for fitting.
      }
      local entryCount = 0

      -- Add base entry (only if enabled).
      if baseEnabled then
        entryCount = entryCount + 1
        group.entries[entryCount] = { meshPath = piece.baseMesh.meshPath, weight = baseWeight }
        group.totalWeight = baseWeight
      end

      -- Add variations (only enabled ones).
      for j = 1, #variations do
        local variation = variations[j]
        local varEnabled = (states[variation.varId] ~= false)
        if varEnabled then
          local varWeight = varWeights[variation.varId] or 1.0
          entryCount = entryCount + 1
          group.entries[entryCount] = { meshPath = variation.meshPath, weight = varWeight }
          group.totalWeight = group.totalWeight + varWeight
        end
      end

      groups[pieceIndex] = group
    end
  end

  return groups
end

-- Checks if a piece is enabled for the given spline.
local function getPieceEnabled(spline, pieceId)
  if not spline.pieceEnabledStates then
    return true -- Default to enabled if no state exists
  end
  return spline.pieceEnabledStates[pieceId] ~= false
end

-- Sets the enabled state for a piece for the given spline.
local function setPieceEnabled(spline, pieceId, enabled)
  spline.pieceEnabledStates = spline.pieceEnabledStates or {}
  spline.pieceEnabledStates[pieceId] = enabled
end

-- Extracts the rect and pizza mesh paths from a mesh kit.
local function getRectAndPizzaMeshPaths(meshKit)
  if not meshKit or #meshKit == 0 then
    return nil, nil
  end

  local rectMeshPath, pizzaMeshPath = nil, nil
  for i = 1, #meshKit do
    local mesh = meshKit[i]
    if mesh.fileName == rectMeshFileName then
      rectMeshPath = mesh.meshPath
    elseif mesh.fileName == pizzaMeshFileName then
      pizzaMeshPath = mesh.meshPath
    end
  end

  return rectMeshPath, pizzaMeshPath
end


-- Public interface.
M.getSidewalkKit =                                      getSidewalkKit
M.buildSidewalkKit =                                    buildSidewalkKit
M.buildDistributionGroups =                             buildDistributionGroups

M.getRectAndPizzaMeshPaths =                            getRectAndPizzaMeshPaths

M.getPieceEnabled =                                     getPieceEnabled
M.setPieceEnabled =                                     setPieceEnabled

return M