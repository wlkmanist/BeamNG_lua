-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function nonEmpty(value)
  if value == nil then return nil end
  value = tostring(value)
  return value ~= "" and value or nil
end

local function assetName(obj)
  local asset = obj.getField and nonEmpty(obj:getField("shapeName", 0)) or nil
  if not asset and obj.getModelFile then asset = nonEmpty(obj:getModelFile()) end
  if not asset then return nil end
  local _, filename = path.split(asset)
  return nonEmpty(filename)
end

local function typePrefix(obj)
  local className = obj:getClassName()
  if className == "Prefab" or className == "PrefabInstance" then return "[p]" end
  if className == "TSStatic" then return "[s]" end
  if className == "BeamNGVehicle" then return "[v]" end
  return nil
end

function M.objectName(obj, objectId)
  if objectId then obj = scenetree.findObjectById(objectId) end
  if not obj then return objectId and ("deleted #" .. objectId) or "missing" end
  local name = (obj.getName and nonEmpty(obj:getName()))
    or (obj.getInternalName and nonEmpty(obj:getInternalName()))
    or assetName(obj)
    or string.format("%s #%d", obj:getClassName(), obj:getID())
  local prefix = typePrefix(obj)
  return prefix and (prefix .. " " .. name) or name
end

return M
