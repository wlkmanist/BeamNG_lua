-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Minimal exporter: dumps current vehicle nodes (points) and beams (edges) to JSON
-- Usage:
--   extensions.util_nodeBeamExport.exportFile() -- writes to <vehicleDirectory>/export_<N>.nbexport.json

local M = {}

local logTag = 'nodeBeamExport'

-- Returns the GE vehicle object and its data table for the current player vehicle
local function getActiveVehicleAndData()
  local veh = getPlayerVehicle(0)
  if not veh then return nil, nil end
  local vdata = extensions.core_vehicle_manager.getVehicleData(veh:getId())
  return veh, vdata
end

-- Build a simple graph: points = nodes, edges = beams
-- positions are in game coordinates as returned by veh:getNodePosition(id)
local function buildGraph()
  local veh, vdata = getActiveVehicleAndData()
  if not veh or not vdata or not vdata.vdata then return nil end

  local out = {
    vehicle = {
      id = veh:getId(),
      jbeam = veh:getJBeamFilename(),
      name = veh.jbeam
    },
    nodes = {},
    beams = {}
  }

  local nodeCount = veh:getNodeCount() or 0
  local nodesMeta = vdata.vdata.nodes or {}

  for i = 0, nodeCount - 1 do
    local p = veh:getNodePosition(i)
    if p then
      local meta = nodesMeta[i]
      local entry = {
        id = i,
        -- Convert to Z-up: X = X, Y = Z, Z = -Y
        pos = {p.x, p.z, -p.y}
      }
      if meta and meta.name then entry.name = meta.name end
      table.insert(out.nodes, entry)
    end
  end

  for _, b in pairs(vdata.vdata.beams or {}) do
    if b and b.id1 and b.id2 then
      table.insert(out.beams, { id = b.cid or -1, n1 = b.id1, n2 = b.id2 })
    end
  end

  return out
end

local function ensureDir(dir)
  if not FS:directoryExists(dir) then
    FS:directoryCreate(dir)
  end
end

-- Suggest a filename under the vehicle base path (fallback: user path)
local function suggestFilename()
  local _, vdata = getActiveVehicleAndData()
  if not vdata or not vdata.vehicleDirectory then
    log('E', logTag, 'No vehicle directory available for export')
    return nil
  end
  local dir = vdata.vehicleDirectory
  if string.sub(dir, -1) ~= '/' then dir = dir .. '/' end

  if not FS:directoryExists(dir) then
    FS:directoryCreate(dir)
  end

  local files = FS:findFiles(dir, '*.nbexport.json', -1, false, false) or {}
  local maxIdx = 0
  for _, f in ipairs(files) do
    local name = string.match(f, '([^/\\]+)$')
    local n = name and string.match(name, '^export_(%d+)%.nbexport%.json$')
    n = n and tonumber(n) or nil
    if n and n > maxIdx then maxIdx = n end
  end

  local nextIdx = maxIdx + 1
  return string.format('%sexport_%d.nbexport.json', dir, nextIdx)
end

-- Export graph to JSON. If filename is nil, uses suggestFilename()
local function exportFile(filename)
  local graph = buildGraph()
  if not graph then
    log('E', logTag, 'No active vehicle or data available to export')
    return false
  end

  filename = filename or suggestFilename()
  if not filename then return false end

  local dir = string.match(filename, '^(.*)[/\\]')
  if dir then ensureDir(dir) end

  local ok = jsonWriteFile(filename, graph, true)
  if ok then
    log('I', logTag, 'Exported nodes/beams to ' .. tostring(filename))
  else
    log('E', logTag, 'Failed writing file ' .. tostring(filename))
  end
  return ok
end

M.exportFile = exportFile
M.suggestFilename = suggestFilename

return M


