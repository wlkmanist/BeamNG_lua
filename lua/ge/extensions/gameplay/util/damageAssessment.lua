-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

local params = {
  maxDamagePerCell = 500000,
}

local damageThresholds = {
  {10000, "Minor", 1},
  {30000, "Moderate", 2},
  {50000, "Severe", 3},
}

local damageLocationNames = {
  frontCenter = {
    name = "Front Center",
    id = 0,
    damageRequirements = {
      cells = {
        3, 4, 5,
      },
    }
  },
  fontLeft = {
    name = "Front Left",
    id = 1,
    damageRequirements = {
      cells = {
        6, 7, 8,
      },
    }
  },
  frontRight = {
    name = "Front Right",
    id = 2,
    damageRequirements = {
      cells = {
        0, 1, 2,
      },
    }
  },
  leftCenter = {
    name = "Left Center",
    id = 3,
    damageRequirements = {
      cells = {
        15, 16, 17,
      },
    }
  },
  rightCenter = {
    name = "Right Center",
    id = 4,
    damageRequirements = {
      cells = {
        9, 10, 11,
      },
    }
  },
  rearLeft = {
    name = "Rear Left",
    id = 5,
    damageRequirements = {
      cells = {
        26, 25, 24,
      },
    }
  },
  rearRight = {
    name = "Rear Right",
    id = 6,
    damageRequirements = {
      cells = {
        20, 19, 18,
      },
    }
  },
  rearCenter = {
    name = "Rear",
    id = 7,
    damageRequirements = {
      cells = {
        21, 22, 23,
      },
    }
  },
  top = {
    name = "Top",
    id = 7,
    damageRequirements = {
      cells = {
        2, 5, 8, 11, 14, 17, 20, 23, 26,
      },
    }
  },
  bottom = {
    name = "Bottom",
    id = 8,
    damageRequirements = {
      cells = {
        0, 3, 6, 9, 12, 15, 18, 21, 24,
      }
    }
  },
  front = {
    name = "Front",
    id = 9,
    damageRequirements = {
      cells = {
        0, 1, 2, 3, 4, 5, 6, 7, 8,
      },
    }
  },
  rear = {
    name = "Rear",
    id = 10,
    damageRequirements = {
      cells = {
        18, 19, 20, 21, 22, 23, 24, 25, 26,
      },
    }
  },
  right = {
    name = "Right",
    id = 11,
    damageRequirements = {
      cells = {
        20, 19, 18, 9, 10, 11, 0, 1, 2,
      },
    }
  },
  left = {
    name = "Left",
    id = 12,
    damageRequirements = {
      cells = {
        26, 25, 24, 15, 16, 17, 6, 7, 8,
      },
    }
  }
}

local noDamageThreshold = 50
local debug = false
local magentaColor = ColorF(1, 0, 1, 1)

local function getOverallDamageLevel(vehId)
  local damage = map.objects[vehId].damage
  if damage <= noDamageThreshold then
    return {damageName = "No damage", damageSeverity = 0}
  end
  for i = #damageThresholds, 1, -1 do
    local threshold = damageThresholds[i]
    if damage >= threshold[1] then
      return {damageName = damageThresholds[math.min(i+1, #damageThresholds)][2], damageSeverity = damageThresholds[math.min(i+1, #damageThresholds)][3]}
    end
  end
  return {damageName = damageThresholds[1][2], damageSeverity = damageThresholds[1][3]}
end


-- Calculate cell sizes for non-uniform grid
local function getCellSize(axis, axisLength, cutDepth)
  if axis == 0 or axis == 2 then -- outer cells
    return cutDepth
  else -- middle cell (axis == 1)
    return axisLength - 2 * cutDepth
  end
end

local function getCellOffset(axis, axisLength, cutDepth)
  if axis == 0 then -- first cell
    return -axisLength/2 + cutDepth/2
  elseif axis == 1 then -- middle cell
    return 0
  else -- last cell (axis == 2)
    return axisLength/2 - cutDepth/2
  end
end
local function getSectionsDamageInfoRaw(vehId)
  if vehId == nil then
    vehId = be:getPlayerVehicleID(0)
  end
  local veh = scenetree.findObjectById(vehId)
  local oobb = veh:getSpawnWorldOOBB()
  local centerVec = oobb:getCenter()
  local halfExtents = oobb:getHalfExtents()


  local sortedExtents = {halfExtents.x, halfExtents.y, halfExtents.z}
  table.sort(sortedExtents)
  local medianAxis = sortedExtents[2] * 2

  local xAxis = oobb:getAxis(0)
  local yAxis = oobb:getAxis(1)
  local zAxis = oobb:getAxis(2)

  -- calculate cut depth for each axis
  local xAxisLength = halfExtents.x * 2
  local yAxisLength = halfExtents.y * 2
  local zAxisLength = halfExtents.z * 2
  local xCutDepth = math.min(xAxisLength, medianAxis) / 3
  local yCutDepth = math.min(yAxisLength, medianAxis) / 3
  local zCutDepth = math.min(zAxisLength, medianAxis) / 3

  local sectionsDamageInfoRaw = {}

  for i = 0, 26 do
    -- convert linear index to 3D grid coordinates
    local x = math.floor((i % 9) / 3)
    local y = math.floor(i / 9)
    local z = i % 3

    -- calculate non-uniform cell positions and sizes
    local xCellSize = getCellSize(x, xAxisLength, xCutDepth)
    local yCellSize = getCellSize(y, yAxisLength, yCutDepth)
    local zCellSize = getCellSize(z, zAxisLength, zCutDepth)

    local offset = vec3(
      getCellOffset(x, xAxisLength, xCutDepth), -- offset from center bb
      getCellOffset(y, yAxisLength, yCutDepth),
      getCellOffset(z, zAxisLength, zCutDepth)
    )

    local worldPos = centerVec +
      xAxis * offset.x +
      yAxis * offset.y +
      zAxis * offset.z

    local sectionDamageInfo = {
      sectionBeamDamage = veh:getSectionBeamDamage(i),
      sectionCollisionDamage = veh:getSectionCollisionDamage(i),
    }
    sectionsDamageInfoRaw[i] = sectionDamageInfo

    if debug then
      local halfCell = vec3(xCellSize, yCellSize, zCellSize) * 0.5
      local corners = {
        worldPos + xAxis * halfCell.x + yAxis * halfCell.y + zAxis * halfCell.z,
        worldPos + xAxis * halfCell.x + yAxis * halfCell.y - zAxis * halfCell.z,
        worldPos + xAxis * halfCell.x - yAxis * halfCell.y + zAxis * halfCell.z,
        worldPos + xAxis * halfCell.x - yAxis * halfCell.y - zAxis * halfCell.z,
        worldPos - xAxis * halfCell.x + yAxis * halfCell.y + zAxis * halfCell.z,
        worldPos - xAxis * halfCell.x + yAxis * halfCell.y - zAxis * halfCell.z,
        worldPos - xAxis * halfCell.x - yAxis * halfCell.y + zAxis * halfCell.z,
        worldPos - xAxis * halfCell.x - yAxis * halfCell.y - zAxis * halfCell.z
      }


      local edges = {
        {1,2}, {1,3}, {1,5},
        {2,4}, {2,6},
        {3,4}, {3,7},
        {4,8},
        {5,6}, {5,7},
        {6,8},
        {7,8}
      }

      for _, edge in ipairs(edges) do
        debugDrawer:drawLine(corners[edge[1]], corners[edge[2]], magentaColor)
      end

      debugDrawer:drawText(worldPos, string.format("%i|%i", sectionDamageInfo.sectionBeamDamage, sectionDamageInfo.sectionCollisionDamage), magentaColor)
    end
  end
  return sectionsDamageInfoRaw
end

local function calculateDamageVariation(tableNumbers, maxValue)
  if not tableNumbers or #tableNumbers <= 1 then
    return 0
  end

  maxValue = (maxValue or params.maxDamagePerCell) / 2

  -- Calculate mean
  local sum = 0
  for _, value in ipairs(tableNumbers) do
    sum = sum + value
  end
  local mean = sum / #tableNumbers

  -- Calculate variance
  local variance = 0
  for _, value in ipairs(tableNumbers) do
    local adjustedValue = math.max(value, 0)
    variance = variance + (adjustedValue - mean) ^ 2
  end
  variance = variance / #tableNumbers

  -- Calculate standard deviation and normalize
  local stdDev = math.sqrt(variance)
  return math.min(stdDev / maxValue, 1.0)
end

-- data.vehId : the vehicle id to get the damage from, can be nil (in which case the player's vehicle will be used)
-- if oldSectionsDamage is specified, this function will return the difference between the new and old sections damage (useful to know the damages for a specific crash), if not specified it will return the locations of the damages
local function getTextualDamageLocations(oldSectionsDamageInfoRaw, newSectionsDamageInfoRaw)
  local maxCellDamage = 0
  local textualDamageLocations = {
    damagedLocations = {},
    mostDamagedLocation = nil,
    totalDamage = 0
  }

  local maxDamageScore = 0

  for _, location in pairs(damageLocationNames) do
    textualDamageLocations.damagedLocations[location.name] =
    {
      totalDamage = 0,
      maxCellDamage = 0,
      averageCellDamage = 0,
      damageVariation = 0, -- the bigger the variation, the more the damage is not uniform across the cells
      damageLocationScore = 0,
      name = location.name,
    }
    for _, cellId in ipairs(location.damageRequirements.cells) do
      local damageDiff = newSectionsDamageInfoRaw[cellId] - oldSectionsDamageInfoRaw[cellId]
      if damageDiff > 0 then
        textualDamageLocations.damagedLocations[location.name].totalDamage = textualDamageLocations.damagedLocations[location.name].totalDamage + damageDiff
        textualDamageLocations.damagedLocations[location.name].maxCellDamage = math.max(textualDamageLocations.damagedLocations[location.name].maxCellDamage, damageDiff)
        maxCellDamage = math.max(maxCellDamage, damageDiff)
      end
    end
    textualDamageLocations.damagedLocations[location.name].averageCellDamage = textualDamageLocations.damagedLocations[location.name].totalDamage / #location.damageRequirements.cells

    -- Calculate damage variation using the dedicated function
    local cellDamages = {}
    for _, cellId in ipairs(location.damageRequirements.cells) do
      local damageDiff = newSectionsDamageInfoRaw[cellId] - oldSectionsDamageInfoRaw[cellId]
      table.insert(cellDamages, damageDiff)
    end
    textualDamageLocations.damagedLocations[location.name].damageVariation = calculateDamageVariation(cellDamages, textualDamageLocations.damagedLocations[location.name].maxCellDamage)
    textualDamageLocations.damagedLocations[location.name].intensity = textualDamageLocations.damagedLocations[location.name].totalDamage / (maxCellDamage * #location.damageRequirements.cells)
    textualDamageLocations.damagedLocations[location.name].damageScore = textualDamageLocations.damagedLocations[location.name].intensity * textualDamageLocations.damagedLocations[location.name].totalDamage * textualDamageLocations.damagedLocations[location.name].averageCellDamage / 1000000
    if textualDamageLocations.damagedLocations[location.name].damageScore > maxDamageScore then
      maxDamageScore = textualDamageLocations.damagedLocations[location.name].damageScore
      textualDamageLocations.mostDamagedLocation = location.name
    end
  end

  -- dump(textualDamageLocations.mostDamagedLocation)

  -- for _, location in pairs(damageLocationNames) do
  --   if textualDamageLocations.damagedLocations[location.name] then
  --     if location.name == "Front Center" or location.name == "Front Left" or location.name == "Front Right" or location.name == "Front"then
  --       dump(textualDamageLocations.damagedLocations[location.name])
  --     end
  --   end
  -- end

  -- Find the best damage location based on the highest score
  local bestLocation = nil
  local highestScore = 0
  for locationName, locationData in pairs(textualDamageLocations.damagedLocations) do
    if locationData.damageLocationScore > highestScore then
      highestScore = locationData.damageLocationScore
      bestLocation = locationName
    end
  end
  textualDamageLocations.bestDamageLocation = bestLocation
  textualDamageLocations.bestDamageScore = highestScore

  return textualDamageLocations
end

-- used to know where an impact happened
local function getTextualDamageLocationsByType(data, damageType)
  if data == nil then data = {} end

  if data.vehId == nil then data.vehId = be:getPlayerVehicleID(0) end

  if data.oldSectionsDamageRaw == nil then
    data.oldSectionsDamageRaw = {}
    for i = 0, 26 do
      data.oldSectionsDamageRaw[i] = 0
    end
  else
    for cellId, cellDamageInfo in pairs(data.oldSectionsDamageRaw) do
      data.oldSectionsDamageRaw[cellId] = cellDamageInfo[damageType]
    end
  end

  if data.newSectionsDamageInfoRaw == nil then
    data.newSectionsDamageInfoRaw = {}
    for cellId, cellDamageInfo in pairs(getSectionsDamageInfoRaw(data.vehId)) do
      data.newSectionsDamageInfoRaw[cellId] = cellDamageInfo[damageType]
    end
  else
    for cellId, cellDamageInfo in pairs(data.newSectionsDamageInfoRaw) do
      data.newSectionsDamageInfoRaw[cellId] = cellDamageInfo[damageType]
    end
  end

  return getTextualDamageLocations(data.oldSectionsDamageRaw, data.newSectionsDamageInfoRaw)
end

-- used to know where an impact happened
local function getTextualCollisionDamageLocations(data)
  return getTextualDamageLocationsByType(data, "sectionCollisionDamage")
end

-- used to know where damage on the vehicle happened
local function getTextualBeamDamageLocations(data)
  return getTextualDamageLocationsByType(data, "sectionBeamDamage")
end

local function onSerialize()
  return {
    debug = debug,
  }
end

local function onDeserialized(data)
  debug = data.debug
end

local function onUpdate()
  if debug then
    getSectionsDamageInfoRaw()
  end
end

local function setDebug(newDebug)
  debug = newDebug
end

M.onUpdate = onUpdate
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

M.setDebug = setDebug
M.getOverallDamageLevel = getOverallDamageLevel
M.getSectionsDamageInfoRaw = getSectionsDamageInfoRaw
M.getTextualCollisionDamageLocations = getTextualCollisionDamageLocations
M.getTextualBeamDamageLocations = getTextualBeamDamageLocations
M.calculateDamageVariation = calculateDamageVariation

return M
