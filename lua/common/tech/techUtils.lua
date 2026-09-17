-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.getSurfaceHeight = function(pos)
  local get = obj and obj or be

  -- first, try a reasonable position for the raycast - two meters above the object
  local topPos = vec3(pos.x, pos.y, pos.z + 2)
  local height = get:getSurfaceHeightBelow(topPos)
  if height > -1e10 then -- the function returns -1e20 when the raycast fails
    return height
  end

  -- try a safe z - 100km above
  topPos.z = 1e5
  height = get:getSurfaceHeightBelow(topPos)
  if height > -1e10 then
    return height
  end

  -- both raycasts failed, use the input z value
  return pos.z
end

local function tableToVec3OrQuat(tbl)
  if type(tbl) == 'table' then
    if type(tbl.x) == 'number' and type(tbl.y) == 'number' and type(tbl.z) == 'number' then
      if tbl.w == nil then return vec3(tbl.x, tbl.y, tbl.z) end
      if type(tbl.w) == 'number' then return quat(tbl.x, tbl.y, tbl.z, tbl.w) end
    end
  end
  return tbl
end

local function tableToVec3Recursive(tbl)
  if type(tbl) ~= 'table' then return tbl end
  for k, v in pairs(tbl) do
    local newV = tableToVec3OrQuat(v)
    tbl[k] = newV
    if type(newV) == "table" then
      tableToVec3Recursive(newV)
    end
  end
  return tbl
end

local migrateKeysMapping = {
  ['updateTime'] = 'requestedUpdateTime',
  ['isRenderAnnotations'] = 'renderAnnotations',
  ['isRenderColours'] = 'renderColours',
  ['isRenderDepth'] = 'renderDepth',
  ['isRenderInstance'] = 'renderInstance',
}

local function migrateOldKeysRecursive(tbl)
  if type(tbl) ~= 'table' then return tbl end
  for k, v in pairs(tbl) do
    if migrateKeysMapping[k] ~= nil then
      tbl[migrateKeysMapping[k]] = v
      tbl[k] = nil
    end
    if type(v) == "table" then
      migrateOldKeysRecursive(v)
    end
  end
  return tbl
end

M.tableToVec3Recursive = tableToVec3Recursive
M.migrateOldKeysRecursive = migrateOldKeysRecursive

return M