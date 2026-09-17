-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Vehicle tools: list/details/files/parts, reset/reload, pose, instability tracking.

local shared = require('mcp/shared')
local M = {}

-- Physics instability events, recorded via the engine's onInstabilityDetected hook.
function M.onInstabilityDetected(vid, returnData)
  local v = getObjectByID(vid)
  local log = shared.instabilityLog
  log[#log + 1] = { time = os.date("%H:%M:%S"), vid = vid, jbeam = v and v:getJBeamFilename() }
  if #log > 50 then table.remove(log, 1) end
end

function M.get_vehicles()
  local out = {}
  for _, veh in ipairs(getAllVehicles()) do
    local jbeam = veh:getJBeamFilename()
    local md = jbeam and core_vehicles.getModel(jbeam)
    md = md and md.model
    local name = jbeam
    if md and md.Name then
      name = md.Brand and (md.Brand .. " " .. md.Name) or md.Name
    end
    out[#out + 1] = { id = veh:getId(), jbeam = jbeam, name = name }
  end
  return jsonEncode(out), false
end

function M.get_player_vehicle_id()
  return tostring(be:getPlayerVehicleID(0)), false
end

function M.get_vehicle(args)
  local vid = shared.argVehId(args)
  local veh = getObjectByID(vid)
  if not veh then return "no vehicle " .. tostring(vid), true end
  local d = core_vehicles.getVehicleDetails(vid) or {}
  local cur, model = d.current or {}, d.model or {}
  local pos = veh:getPosition()
  return jsonEncode({
    id = vid,
    jbeam = veh:getJBeamFilename(),
    name = model.Brand and (model.Brand .. " " .. (model.Name or "")) or model.Name,
    configKey = cur.config_key,
    pcFile = cur.pc_file,
    position = { x = pos.x, y = pos.y, z = pos.z },
    speed = veh:getVelocity():length(),
  }), false
end

function M.get_vehicle_files(args)
  local b = shared.vehData(args)
  if not b then return "no vehicle data", true end
  local jbeamIO = require('jbeam/io')
  local files = {}
  for partName in pairs(b.vdata.activePartsData or {}) do
    local _, fn = jbeamIO.getPart(b.ioCtx, partName)
    if fn then files[fn] = true end
  end
  return jsonEncode({
    vehicleDirectory = b.vehicleDirectory,
    directoriesLoaded = b.directoriesLoaded,
    pcFile = b.config and b.config.partConfigFilename,
    jbeamFiles = tableKeysSorted(files),
  }), false
end

function M.get_part_tree(args)
  local b = shared.vehData(args)
  local tree = b and b.config and b.config.partsTree
  if not tree then return "no part tree", true end
  -- flatten to slot path -> chosen part name
  local out = {}
  local function walk(node)
    if node.chosenPartName and node.chosenPartName ~= "" then out[node.path] = node.chosenPartName end
    if node.children then for _, c in pairs(node.children) do walk(c) end end
  end
  walk(tree)
  return jsonEncode(out), false
end

function M.get_instability(args)
  local out = jsonEncode({ count = #shared.instabilityLog, events = shared.instabilityLog })
  if not (args and args.clear == false) then shared.instabilityLog = {} end
  return out, false
end

function M.reset_vehicle()
  local veh = be:getPlayerVehicle(0)
  if not veh then return "no player vehicle", true end
  be:resetVehicle(0)
  return "reset player vehicle " .. veh:getId(), false
end

function M.reload_vehicle()
  local veh = be:getPlayerVehicle(0)
  if not veh then return "no player vehicle", true end
  core_vehicle_manager.reloadVehicle(0)
  return "reloaded player vehicle " .. veh:getId(), false
end

-- Get a vehicle's pose (position + rotation). Pair with set_position to save/restore it.
function M.get_position(args)
  local vid = shared.argVehId(args)
  local veh = getObjectByID(vid)
  if not veh then return "no vehicle " .. tostring(vid), true end
  local p = veh:getPosition()
  local q = quatFromDir(veh:getDirectionVector(), veh:getDirectionVectorUp())
  return jsonEncode({ id = vid, pos = { x = p.x, y = p.y, z = p.z }, rot = { x = q.x, y = q.y, z = q.z, w = q.w } }), false
end

-- Set a vehicle's pose. Accepts the JSON from get_position (rot optional = keep current).
function M.set_position(args)
  local vid = shared.argVehId(args)
  local veh = getObjectByID(vid)
  if not veh then return "no vehicle " .. tostring(vid), true end
  local p = args and args.pos
  if type(p) ~= "table" then return "missing 'pos' {x,y,z}", true end
  local r = args and args.rot
  local rot = (type(r) == "table") and quat(r.x, r.y, r.z, r.w) or quatFromDir(veh:getDirectionVector(), veh:getDirectionVectorUp())
  spawn.safeTeleport(veh, vec3(p.x, p.y, p.z), rot, nil, nil, nil, nil, true)
  return string.format("set vehicle %d to (%.2f, %.2f, %.2f)", vid, p.x, p.y, p.z), false
end

M.schemas = {
  get_vehicles = { description = "List currently spawned vehicles (id, jbeam, display name) as JSON." },
  get_player_vehicle_id = { description = "Return the id of the current player vehicle (use with the id arg of other vehicle tools)." },
  get_vehicle = {
    description = "Vehicle details (id, jbeam, name, config, pc file, position, speed) as JSON.",
    inputSchema = { type = "object", properties = shared.vehIdProp },
  },
  get_vehicle_files = {
    description = "Files used by a vehicle: jbeam files of active parts, loaded directories, and .pc config path, as JSON.",
    inputSchema = { type = "object", properties = shared.vehIdProp },
  },
  get_part_tree = {
    description = "Vehicle part config as a JSON map of slot path -> chosen part name.",
    inputSchema = { type = "object", properties = shared.vehIdProp },
  },
  get_instability = {
    description = "Physics instability events (a vehicle going unstable/exploding) since the last check. Returns count + events and clears the buffer.",
    inputSchema = { type = "object", properties = { clear = { type = "boolean", description = "Clear the buffer after reading (default true)" } } },
  },
  reset_vehicle = { description = "Reset/repair the player vehicle in place (physics reset)." },
  reload_vehicle = { description = "Reload the player vehicle from disk, re-reading its jbeam (picks up file edits)." },
  get_position = {
    description = "Get a vehicle's pose (position + rotation) as JSON. Save it, then pass it back to set_position to return the vehicle to that pose.",
    inputSchema = { type = "object", properties = shared.vehIdProp },
  },
  set_position = {
    description = "Set a vehicle's pose (teleports + repairs). Accepts the JSON from get_position; rot is optional (keeps current heading if omitted).",
    inputSchema = { type = "object", properties = {
      pos = { type = "object", description = "{x,y,z}" },
      rot = { type = "object", description = "{x,y,z,w} (optional)" },
      id = shared.vehIdProp.id,
    }, required = { "pos" } },
  },
}

return M
