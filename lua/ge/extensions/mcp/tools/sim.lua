-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Simulation control: pause/step/resume the physics core and set the time scale.

local M = {}

function M.get_simulation_state()
  return jsonEncode({
    physicsRunning = be:getPhysicsRunning(),
    timeScale = be:getSimulationTimeScale(),
    speedFactor = be:getPhysicsSpeedFactor(),
    deterministic = be:getPhysicsDeterministic(),
    enabled = be:getEnabled(),
  }), false
end

function M.set_simulation_speed(args)
  local s = tonumber(args and args.scale)
  if not s then return "missing 'scale' (1=normal, <1=slow motion, >1=fast)", true end
  be:setSimulationTimeScale(s)
  return "simulation time scale = " .. s, false
end

function M.pause_physics()
  be:setPhysicsRunning(false)
  return "physics paused (rendering continues). Use step_physics to advance, resume_physics to continue.", false
end

function M.resume_physics()
  be:setPhysicsRunning(true)
  return "physics resumed", false
end

-- Advance the physics core by N ticks then leave it paused (frame-by-frame debugging).
function M.step_physics(args)
  local n = math.max(1, math.floor(tonumber(args and args.steps) or 1))
  be:setPhysicsRunning(false)
  be:physicsStep(n)
  return "stepped " .. n .. " physics tick(s); physics left paused", false
end

M.schemas = {
  get_simulation_state = { description = "Physics/simulation state as JSON: physicsRunning, timeScale, speedFactor, deterministic, enabled." },
  set_simulation_speed = {
    description = "Set the simulation time scale: 1 = normal, <1 = slow motion (e.g. 0.25), >1 = fast forward.",
    inputSchema = { type = "object", properties = { scale = { type = "number" } }, required = { "scale" } },
  },
  pause_physics = { description = "Freeze the physics core (vehicles stop simulating; rendering/camera keep running). Pair with step_physics / resume_physics." },
  resume_physics = { description = "Resume the physics core after pause_physics." },
  step_physics = {
    description = "Advance the physics core by N ticks then leave it paused (frame-by-frame debugging).",
    inputSchema = { type = "object", properties = { steps = { type = "integer", description = "Number of physics ticks (default 1)" } } },
  },
}

return M
