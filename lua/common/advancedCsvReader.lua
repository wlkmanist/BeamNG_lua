-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt


-- Usage Example:
-- local csvParser = require('advancedCsvReader')
-- local records, err = csvParser.parseCSVFile("your_file.csv", ",") -- Specify delimiter if not comma
-- if records then
--   for _, record in ipairs(records) do
--     dump(record)
--   end
-- else
--   print("Error reading file:", err)
-- end


-- Module declaration
local M = {}

-- Function to trim leading and trailing whitespace from a string
local function trim(s)
  return (s:match("^%s*(.-)%s*$"))
end

-- Function to infer the data type of a value
-- Converts to a number if possible; otherwise, leaves it as a string
local function inferType(value)
  if tonumber(value) then
    return tonumber(value)
  else
    return value
  end
end

-- Function to split a line of CSV into fields
-- Handles quoted fields and escaped quotes
local function splitLine(line, delimiter)
  local fields, field, inQuotes, escapeNext = {}, "", false, false
  for i = 1, #line do
    local c = line:sub(i, i)
    if escapeNext then
      field = field .. c
      escapeNext = false
    elseif c == '"' then
      if inQuotes and line:sub(i + 1, i + 1) == '"' then
        escapeNext = true
      else
        inQuotes = not inQuotes
      end
    elseif c == delimiter and not inQuotes then
      fields[#fields + 1] = trim(field)
      field = ""
    else
      field = field .. c
    end
  end
  fields[#fields + 1] = trim(field)
  return fields
end

-- Main function to parse a CSV file
-- filePath: string - Path to the CSV file
-- useHeaderAsKeys: boolean (optional) - Flag to use header as keys for each row, defaults to true
-- delimiter: string (optional) - Delimiter used in the CSV file, defaults to ","
-- Returns a table of data or nil and an error message
local function parseCSVFile(filePath, useHeaderAsKeys, delimiter)
  delimiter = delimiter or ","
  useHeaderAsKeys = useHeaderAsKeys == nil and true or useHeaderAsKeys
  local file, err = io.open(filePath, "r")
  if not file then return nil, err end

  local header, data, isHeaderProcessed = {}, {}, false
  for line in file:lines() do
    -- Ignore lines starting with '#' or ';' (comments) and empty lines
    if #line > 0 and not line:match("^#") and not line:match("^;") then
      local fields = splitLine(line, delimiter)
      if not isHeaderProcessed then
        if #fields == 0 then
          file:close()
          return nil, 'CSV file missing header: ' .. tostring(filePath)
        end
        header = fields
        isHeaderProcessed = true
      else
        local record = {}
        for i = 1, #header do
          if useHeaderAsKeys then
            record[header[i]] = inferType(fields[i] or "")
          else
            record[i] = inferType(fields[i] or "")
          end
        end
        data[#data + 1] = record
      end
    end
  end

  file:close()
  return data, nil, header
end

-- Expose the parseCSVFile function in the module
M.parseCSVFile = parseCSVFile

-- Return the module
return M