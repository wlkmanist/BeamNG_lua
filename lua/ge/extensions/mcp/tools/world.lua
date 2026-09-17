-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- World/navigation: list & load levels, trigger bound actions, recover/remove vehicles, query ground.

local shared = require('mcp/shared')
local M = {}

local function v(t) return t and vec3(t.x or t[1], t.y or t[2], t.z or t[3]) end

function M.list_levels()
  if not (core_levels and core_levels.getList) then return "core_levels unavailable", true end
  local out = {}
  for _, l in ipairs(core_levels.getList() or {}) do
    out[#out + 1] = { name = l.levelName, title = l.title, file = l.fullfilename or l.misFilePath }
  end
  return jsonEncode(out), false
end

-- Load a level by name (levelName from list_levels) or explicit path. Disruptive: reloads the world.
function M.load_level(args)
  args = args or {}
  if not (core_levels and core_levels.startLevel) then return "core_levels unavailable", true end
  local p = args.path
  if not p and args.name then
    for _, l in ipairs(core_levels.getList() or {}) do
      if l.levelName == args.name then p = l.fullfilename or l.misFilePath break end
    end
    if not p and path and path.getPathLevelMain then p = path.getPathLevelMain(args.name) end
  end
  if not p then return "provide 'name' (from list_levels) or 'path' (level main file)", true end
  core_levels.startLevel(p)
  return "loading level: " .. tostring(p), false
end

-- Fire a bound game action by name (e.g. 'recover_vehicle', 'toggleCamera'). state: 'down'/'up'/omit (tap).
function M.trigger_action(args)
  local name = args and args.action
  if type(name) ~= "string" then return "missing 'action' (input action name)", true end
  if not core_input_actions then return "core_input_actions unavailable", true end
  local state = args.state
  if state == "down" then core_input_actions.triggerDown(name)
  elseif state == "up" then core_input_actions.triggerUp(name)
  else core_input_actions.triggerDownUp(name) end
  return "triggered action: " .. name .. (state and (" (" .. state .. ")") or ""), false
end

function M.recover_vehicle(args)
  local vid = shared.argVehId(args)
  local veh = getObjectByID(vid)
  if not veh then return "no vehicle " .. tostring(vid), true end
  if not (spawn and spawn.teleportToLastRoad) then return "spawn.teleportToLastRoad unavailable", true end
  spawn.teleportToLastRoad(veh, { resetVehicle = true })
  return "recovered vehicle " .. vid .. " to last road", false
end

function M.remove_vehicle(args)
  local vid = shared.argVehId(args)
  local veh = getObjectByID(vid)
  if not veh then return "no vehicle " .. tostring(vid), true end
  veh:delete()
  return "removed vehicle " .. vid, false
end

-- Surface height, drivability and ground-model under a point (default: under the player vehicle).
function M.get_ground_at_point(args)
  args = args or {}
  local pos = v(args.pos)
  if not pos then
    local veh = be:getPlayerVehicle(0)
    if veh then pos = veh:getPosition() end
  end
  if not pos then return "provide 'pos' {x,y,z} (no player vehicle to default to)", true end
  local radius = tonumber(args.radius) or 2
  return jsonEncode({
    pos = { x = pos.x, y = pos.y, z = pos.z },
    surfaceHeight = be:getSurfaceHeightBelow(pos),
    drivability = be:getTerrainDrivability(pos, radius),
  }), false
end

M.schemas = {
  list_levels = { description = "List installed levels as JSON: [{name, title, path}]. Use path/name with load_level." },
  load_level = {
    description = "Load a level (reloads the world; disruptive). Provide path (misFilePath from list_levels) or name (levelName).",
    inputSchema = { type = "object", properties = {
      path = { type = "string", description = "Level mis/level file path" },
      name = { type = "string", description = "Level name (resolved via list_levels)" },
    } },
  },
  trigger_action = {
    description = "Fire a bound game action by name (e.g. 'recover_vehicle', 'reset_physics', 'toggleCamera', 'switch_next_vehicle'). Tap by default; pass state='down'/'up' for hold actions.",
    inputSchema = { type = "object", properties = {
      action = { type = "string", description = "Input action name" },
      state = { type = "string", description = "'down', 'up', or omit for a tap" },
    }, required = { "action" } },
  },
  recover_vehicle = {
    description = "Recover a vehicle to the last road (teleport + repair). Default: player vehicle.",
    inputSchema = { type = "object", properties = shared.vehIdProp },
  },
  remove_vehicle = {
    description = "Delete (despawn) a vehicle. Default: player vehicle.",
    inputSchema = { type = "object", properties = shared.vehIdProp },
  },
  get_ground_at_point = {
    description = "Surface height below a point and terrain drivability (0..1) around it. Default point: under the player vehicle.",
    inputSchema = { type = "object", properties = {
      pos = { type = "object", description = "{x,y,z} (default: player vehicle position)" },
      radius = { type = "number", description = "Drivability sample radius in m (default 2)" },
    } },
  },
}

return M
