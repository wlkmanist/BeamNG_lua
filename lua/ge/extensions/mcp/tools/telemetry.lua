-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Telemetry: vehicle electrics, damage, and a one-call situational status snapshot.

local shared = require('mcp/shared')
local M = {}

M.cb = {
  electrics = function(vid, json) shared.asyncResults.electrics = json end,
}

-- Vehicle electrics (rpm, speed, gear, fuel, throttle/brake/steering, lights, ...). Async; pass keys to narrow.
function M.get_electrics(args)
  args = args or {}
  local vid = shared.argVehId(args)
  if not getObjectByID(vid) then return "no vehicle " .. tostring(vid), true end
  local prev = shared.asyncResults.electrics
  shared.asyncResults.electrics = nil
  local snippet
  if type(args.keys) == "table" then
    snippet = "local want=" .. serialize(args.keys) .. " local s={} for _,k in ipairs(want) do s[k]=electrics.values[k] end "
  else
    snippet = "local s={} for k,v in pairs(electrics.values or {}) do local t=type(v) if t=='number' or t=='string' or t=='boolean' then s[k]=v end end "
  end
  be:queueObjectLua(vid, snippet .. [[obj:queueGameEngineLua("extensions.mcp_tools._cb.electrics("..obj:getId()..","..string.format("%q", jsonEncode(s))..")")]])
  if prev then return prev, false end
  return "electrics requested (async); call again in a moment", false
end

function M.get_vehicle_damage(args)
  local vid = shared.argVehId(args)
  local veh = getObjectByID(vid)
  if not veh then return "no vehicle " .. tostring(vid), true end
  return jsonEncode({
    id = vid,
    damageSum = veh.getSectionDamageSum and veh:getSectionDamageSum(),
  }), false
end

-- One-call situational snapshot of GE-side state (vehicle, camera, level, sim). rpm/gear/AI are vehicle-VM -> use get_electrics/get_ai.
function M.get_status()
  local out = {
    sim = { physicsRunning = be:getPhysicsRunning(), timeScale = be:getSimulationTimeScale() },
    vehicleCount = #getAllVehicles(),
    level = getMissionFilename and getMissionFilename(),
  }
  if core_camera then
    out.camera = { mode = core_camera.getActiveCamName and core_camera.getActiveCamName(0) }
    local cp = core_camera.getPosition and core_camera.getPosition()
    if cp then out.camera.pos = { x = cp.x, y = cp.y, z = cp.z } end
  end
  local veh = be:getPlayerVehicle(0)
  if veh then
    local cur = (core_vehicles.getCurrentVehicleDetails() or {}).current or {}
    local p = veh:getPosition()
    out.vehicle = {
      id = veh:getId(),
      jbeam = veh:getJBeamFilename(),
      configKey = cur.config_key,
      pos = { x = p.x, y = p.y, z = p.z },
      speed = veh:getVelocity():length(),
      damage = veh.getSectionDamageSum and veh:getSectionDamageSum(),
    }
  end
  return jsonEncode(out), false
end

M.schemas = {
  get_electrics = {
    description = "Vehicle electrics telemetry (rpm, wheelspeed, gear, fuel, throttle/brake/steering, lights, temps, ...) as JSON. Async: call again in a moment. Pass keys=[...] to fetch only specific values.",
    inputSchema = { type = "object", properties = {
      keys = { type = "array", items = { type = "string" }, description = "Specific electrics keys (default: all scalar values)" },
      id = shared.vehIdProp.id,
    } },
  },
  get_vehicle_damage = {
    description = "Vehicle damage summary (total section damage) as JSON. For detailed per-part damage use run_lua_vehicle with beamstate/damageTracker.",
    inputSchema = { type = "object", properties = shared.vehIdProp },
  },
  get_status = {
    description = "One-call situational snapshot: player vehicle (id/jbeam/config/pos/speed/damage), camera (mode/pos), level, sim state, vehicle count. (rpm/gear via get_electrics, AI via get_ai.)",
  },
}

return M
