-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Camera tools: switch camera mode, control/orbit the camera around a vehicle.

local shared = require('mcp/shared')
local M = {}

local orbitSpin = nil -- continuous orbit-camera rotation around a vehicle

function M.onUpdate(dtReal)
  local o = orbitSpin
  if not o then return end
  o.yaw = (o.yaw + o.speed * (dtReal or 0)) % 360
  core_camera.setRotation(o.vid, vec3(o.yaw, o.pitch, 0))
end

function M.set_camera(args)
  local name = args and args.name
  if type(name) ~= "string" then return "missing 'name' (orbit, driver, chase, external, hood, top, dash, ...)", true end
  if not core_camera then return "core_camera unavailable", true end
  if name ~= "orbit" then orbitSpin = nil end -- leaving orbit stops any spin
  core_camera.setByName(0, name)
  return "camera set to " .. name, false
end

-- Control the orbit camera around a vehicle. spin (deg/s) continuously rotates around it.
function M.orbit_camera(args)
  args = args or {}
  if not core_camera then return "core_camera unavailable", true end
  local vid = shared.argVehId(args)
  if not getObjectByID(vid) then return "no vehicle " .. tostring(vid), true end
  core_camera.setByName(0, "orbit")
  local yaw, pitch, dist, spin = tonumber(args.yaw), tonumber(args.pitch), tonumber(args.distance), tonumber(args.spin)
  if dist then core_camera.setDistance(vid, dist) end
  if spin and spin ~= 0 then
    orbitSpin = { vid = vid, yaw = yaw or 0, pitch = pitch or 20, speed = spin }
    return string.format("orbiting vehicle %d at %g deg/s", vid, spin), false
  end
  orbitSpin = nil
  if yaw or pitch then core_camera.setRotation(vid, vec3(yaw or 0, pitch or 20, 0)) end
  return string.format("orbit set (yaw=%s pitch=%s dist=%s)", tostring(yaw), tostring(pitch), tostring(dist)), false
end

function M.get_camera_state()
  if not core_camera then return "core_camera unavailable", true end
  local p = core_camera.getPosition()
  local q = core_camera.getQuat()
  return jsonEncode({
    mode = core_camera.getActiveCamName and core_camera.getActiveCamName(0),
    pos = { x = p.x, y = p.y, z = p.z },
    rot = { x = q.x, y = q.y, z = q.z, w = q.w },
    fov = core_camera.getFovDeg and core_camera.getFovDeg(),
  }), false
end

-- Switch to the free camera and place it at a pose (persists; the free cam then flies from there on input).
function M.set_free_camera(args)
  args = args or {}
  if not core_camera then return "core_camera unavailable", true end
  core_camera.setByName(0, "free")
  orbitSpin = nil
  local p = args.pos
  if type(p) == "table" then core_camera.globalCameraFunction("free", "setPosition", vec3(p.x, p.y, p.z)) end
  if type(args.rot) == "table" then local r = args.rot; core_camera.globalCameraFunction("free", "setRotation", quat(r.x, r.y, r.z, r.w)) end
  if tonumber(args.fov) then core_camera.globalCameraFunction("free", "setFOV", tonumber(args.fov)) end
  return "free camera set", false
end

M.schemas = {
  set_camera = {
    description = "Switch the player camera mode: orbit, driver, chase, external, hood, top, dash, etc.",
    inputSchema = { type = "object", properties = { name = { type = "string" } }, required = { "name" } },
  },
  orbit_camera = {
    description = "Control the orbit camera around a vehicle (switches to orbit). yaw/pitch in degrees, distance in m. spin (deg/s) continuously rotates around the car; spin=0 stops.",
    inputSchema = { type = "object", properties = {
      yaw = { type = "number", description = "Yaw angle around the car (degrees)" },
      pitch = { type = "number", description = "Pitch angle (degrees, -85..85)" },
      distance = { type = "number", description = "Camera distance (m)" },
      spin = { type = "number", description = "Continuous rotation speed deg/s (0 stops)" },
      id = shared.vehIdProp.id,
    } },
  },
  get_camera_state = { description = "Current camera as JSON: mode, position, rotation (quat), fov." },
  set_free_camera = {
    description = "Switch to the free camera and optionally place it. pos {x,y,z}, rot {x,y,z,w} (quat), fov degrees. The free cam then flies from that pose on input.",
    inputSchema = { type = "object", properties = {
      pos = { type = "object", description = "{x,y,z}" },
      rot = { type = "object", description = "{x,y,z,w} quaternion" },
      fov = { type = "number", description = "Field of view (degrees)" },
    } },
  },
}

return M
