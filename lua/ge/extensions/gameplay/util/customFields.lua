-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Custom key/value pairs, applicable for various objects
-- Also supports an array of tags (as strings)

local C = {}

function C:init()
  self.names = {} -- array of names (keys)
  self.types = {} -- dict of names to types
  self.values = {} -- dict of names to values
  self.sortedTags = {}
  self.tags = {}
end

function C:onSerialize()
  local ret = {
    names = self.names,
    types = self.types,
    values = {},
    tags = self.sortedTags
  }

  for name, val in pairs(self.values) do
    if self.types[name] == 'vec3' or self.types[name] == 'quat' then
      ret.values[name] = val:toTable()
    else
      -- default case
      ret.values[name] = val
    end
  end
  return ret
end

function C:onDeserialized(data)
  self.names = {}
  self.types = {}
  self.values = {}
  self.sortedTags = {}
  self.tags = {}
  for _, name in ipairs(data.names or {}) do
    if data.types[name] == 'string' then
      self:add(name, 'string', tostring(data.values[name]))
    elseif data.types[name] == 'number' then
      self:add(name, 'number', tonumber(data.values[name]))
    elseif data.types[name] == 'boolean' then
      self:add(name, 'boolean', data.values[name])
    elseif data.types[name] == 'vec3' then
      self:add(name, 'vec3', vec3(data.values[name]))
    elseif data.types[name] == 'quat' then
      self:add(name, 'quat', quat(data.values[name]))
    end
  end
  for _, t in ipairs(data.tags or {}) do
    self.tags[t] = 1
  end
  self:updateTags()
end

function C:validate(value, datatype)
  -- TODO: cleanup value assumptions
  if datatype == 'string' then
    return tostring(value)
  elseif datatype == 'number' then
    return tonumber(value) or 0
  elseif datatype == 'boolean' then
    if value == '' or value == '0' or value == 0 or value == 'false' then
      return false
    else
      return value and true or false
    end
  elseif datatype == 'vec3' then
    if type(value) == 'string' then
      local t = split(value:gsub(' ', ''), ',')
      if t[3] then return vec3(tonumber(t[1]), tonumber(t[2]), tonumber(t[3])) else return vec3() end
    else
      return vec3(value)
    end
  elseif datatype == 'quat' then
    if type(value) == 'string' then
      local t = split(value:gsub(' ', ''), ',')
      if t[4] then return quat(tonumber(t[1]), tonumber(t[2]), tonumber(t[3]), tonumber(t[4])) else return quat() end
    else
      return quat(value)
    end
  end
end

function C:set(name, value)
  if not self.values[name] then
    log("W","","Tried to change nonexistent value: " .. name)
    return false
  end
  self.values[name] = value
  if name == 'tags' then
    self:updateTags()
  end
  return true
end

function C:addTag(tag)
  if not tag or self.tags[tag] then
    log("W","","Tried add already existent tag or no tag given")
    return false
  end
  self.tags[tag] = 1
  self:updateTags()
end

function C:removeTag(tag)
  if type(tag) == 'number' then
    tag = self.sortedTags[tag]
  end
  if not tag or not self.tags[tag] then
    log("W","","Tried to remove nonexistent tag")
    return false
  end
  self.tags[tag] = nil
  self:updateTags()
  return true
end

function C:remove(name)
  if not self.values[name] then
    log("W","","Tried to remove nonexistent field: " .. name)
    return false
  end
  self.types[name] = nil
  self.values[name] = nil
  local idx = arrayFindValueIndex(self.names, name)
  table.remove(self.names, idx)
  return true
end

function C:add(name, datatype, value)
  if self.values[name] then
    log("W","","Tried to add already existing value name: " .. name)
    return false
  end
  table.insert(self.names, name)
  self.types[name] = datatype
  self.values[name] = self:validate(value, datatype)
  if name == 'tags' then
    self:updateTags()
  end
  return true
end

function C:has(name) return self.values[name] ~= nil end
function C:get(name)
  if self:has(name) then
    return self.values[name], self.types[name], true
  else
    return nil, nil, false
  end
end

function C:updateTags()
  table.clear(self.sortedTags)
  for k, _ in pairs(self.tags) do
    table.insert(self.sortedTags, k)
  end
  table.sort(self.sortedTags)
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end