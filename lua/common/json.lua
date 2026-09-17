-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
 Bindings to LuaJIT-JSON module
 It decodes SJON format:
  https://github.com/Autodesk/sjson

 Usage:

 local t = json.decode(jsontext)
 local t = json.decode(jsonbuffer)

 If you are looking for the previous Lua SJSON parser, it was moved to ljson.lua.
--]]

local M = {}

local buffer = require('string.buffer')

local _buf = buffer.new()

-- we avoid the buffer.jsondecode here because it would error out when buffer is not fully consumed
local function decode(si)
  if si == nil then return nil end
  if type(si) == 'string' then
    _buf:set(si)
    return _buf:jsondecode()
  end
  -- assume it's a string buffer
  return si:jsondecode()
end

-- public interface
M.encode = buffer.jsonencode
M.decode = decode
return M