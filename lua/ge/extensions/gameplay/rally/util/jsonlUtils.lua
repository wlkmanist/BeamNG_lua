-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- JSON Lines (JSONL) utility functions for reading line-delimited JSON files
-- Used for loading recce recordings (driveline, cuts, transcripts)

local M = {}

-- Check if a line starts with a comment marker
local function startsWithDoubleSlash(line)
  return line:match("^//") ~= nil
end
M.startsWithDoubleSlash = startsWithDoubleSlash

-- Read entire file into memory
local function readFileToMemory(fname)
  local file = io.open(fname, "r")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return content
end
M.readFileToMemory = readFileToMemory

-- Split content into lines
local function splitIntoLines(content)
  local lines = {}
  for line in content:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end
  return lines
end
M.splitIntoLines = splitIntoLines

-- Parse a JSONL file, calling processLine for each valid JSON line
-- Returns array of parsed objects, or nil on error
-- processLine(obj) should return the processed object or nil to skip
function M.parseJsonlFile(fname, processLine, rallyUtil)
  if not FS:fileExists(fname) then
    return nil, "file not found"
  end

  local content = readFileToMemory(fname)
  if not content then
    return nil, "failed to read file"
  end

  local results = {}
  local lines = splitIntoLines(content)

  for _, line in ipairs(lines) do
    line = rallyUtil.trimString(line)
    if line ~= "" and not startsWithDoubleSlash(line) then
      local obj = jsonDecode(line)
      if processLine then
        obj = processLine(obj)
      end
      if obj then
        table.insert(results, obj)
      end
    end
  end

  return results
end

-- Simple JSONL file reader using io.lines (for backward compatibility)
-- Calls callback(obj) for each line
function M.readJsonlLines(fname, callback)
  if not FS:fileExists(fname) then
    return false
  end

  for line in io.lines(fname) do
    local obj = jsonDecode(line)
    if callback then
      callback(obj)
    end
  end

  return true
end

return M

