-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared state and helpers for the mcp tool modules (singleton via require cache).

local M = {}

M.asyncResults = {}   -- async round-trip results (vue, vehLua, ai, hydro, testConfigs)
M.instabilityLog = {} -- physics instability events (filled by the onInstabilityDetected hook)

-- schema snippet reused across vehicle tools
M.vehIdProp = { id = { type = "integer", description = "Vehicle id (default: current player vehicle)" } }

-- vehicle id from args.id, defaulting to the current player vehicle.
function M.argVehId(args) return (args and tonumber(args.id)) or be:getPlayerVehicleID(0) end

-- spawned bundle (parts/config/files/ioCtx) for a vehicle id, or nil.
function M.vehData(args) return core_vehicle_manager.getVehicleData(M.argVehId(args)) end

-- model from args.model, else the current player vehicle's model.
function M.argModel(args)
  if args and args.model then return args.model end
  local veh = be:getPlayerVehicle(0)
  return veh and veh:getJBeamFilename()
end

-- Read beamng.log bytes from byte offset `pos` to EOF. Returns (text, eofPos).
-- pos=nil starts at EOF (returns ""), so it is also used to sample the current size.
-- A shrunk file (rotation/truncation) restarts from 0.
function M.readLogFrom(pos)
  local f = io.open("beamng.log", "r")
  if not f then return nil, pos end
  local size = f:seek("end")
  local start = pos or size
  if size < start then start = 0 end
  f:seek("set", start)
  local data = f:read("*all") or ""
  f:close()
  return data, size
end

return M
