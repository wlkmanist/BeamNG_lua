-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Spawning tools: list configs, spawn/replace a vehicle, and batch-test all configs.

local shared = require('mcp/shared')
local M = {}

local cfgTest = nil -- batch: spawn each config of a model and record errors/instability

function M.onUpdate(dtReal)
  local c = cfgTest
  if not c then return end
  c.timer = c.timer + (dtReal or 0)
  if c.phase == "spawn" then
    c.logPos = select(2, shared.readLogFrom(nil)) -- log EOF before spawn
    c.instStart = #shared.instabilityLog
    core_vehicles.replaceVehicle(c.model, { config = c.keys[c.idx] })
    c.phase, c.timer = "wait", 0
  elseif c.phase == "wait" and c.timer > c.delay then
    local data = shared.readLogFrom(c.logPos) or ""
    local errs = {}
    for line in (data .. "\n"):gmatch("(.-)\r?\n") do
      -- only count errors that name this vehicle/jbeam/parts, to skip ambient level/paint noise
      if line:find("|E|", 1, true) and (line:find(c.model, 1, true) or line:find("jbeam", 1, true) or line:lower():find("skin") or line:find("slot ", 1, true) or line:find("flexbod", 1, true)) then
        errs[#errs + 1] = line:gsub("^%s*%d+%.%d+|E|| ?", "")
      end
    end
    local unstable = #shared.instabilityLog > c.instStart
    local sample = {}
    for i = 1, math.min(3, #errs) do sample[i] = errs[i] end
    c.results[#c.results + 1] = { config = c.keys[c.idx], ok = (#errs == 0 and not unstable), errorCount = #errs, errors = sample, unstable = unstable }
    c.idx = c.idx + 1
    if c.idx > #c.keys then
      shared.asyncResults.testConfigs = { model = c.model, total = #c.results, results = c.results }
      cfgTest = nil
    else
      c.phase, c.timer = "spawn", 0
    end
  end
end

function M.get_configs(args)
  local model = shared.argModel(args)
  if not model then return "no model (no player vehicle; pass 'model')", true end
  local md = core_vehicles.getModel(model)
  if not md or not md.configs then return "no configs for " .. tostring(model), true end
  local keys = {}
  for _, c in pairs(md.configs) do keys[#keys + 1] = c.key end
  table.sort(keys)
  return jsonEncode({ model = model, configs = keys }), false
end

-- Spawn a vehicle (mirrors core_vehicles). Default: replace the current vehicle; add=true spawns an extra one.
function M.spawn(args)
  local model = shared.argModel(args)
  if not model then return "no model (no player vehicle; pass 'model')", true end
  local opt = {}
  if args and args.config then opt.config = args.config end
  local verb = (args and args.add) and "spawned" or "replaced with"
  if args and args.add then core_vehicles.spawnNewVehicle(model, opt) else core_vehicles.replaceVehicle(model, opt) end
  return verb .. " " .. model .. (opt.config and (" [" .. tostring(opt.config) .. "]") or " [default]"), false
end

-- Spawn-test every config of a model. Start it, then poll for progress, then the final report.
function M.test_configs(args)
  if cfgTest then
    return jsonEncode({ running = true, model = cfgTest.model, done = #cfgTest.results, total = #cfgTest.keys, current = cfgTest.keys[cfgTest.idx] }), false
  end
  if shared.asyncResults.testConfigs then
    local r = shared.asyncResults.testConfigs; shared.asyncResults.testConfigs = nil
    return jsonEncode(r), false
  end
  local model = shared.argModel(args)
  if not model then return "no model (no player vehicle; pass 'model')", true end
  local md = core_vehicles.getModel(model)
  if not md or not md.configs then return "no configs for " .. tostring(model), true end
  local keys = {}
  for _, cc in pairs(md.configs) do keys[#keys + 1] = cc.key end
  table.sort(keys)
  cfgTest = { model = model, keys = keys, idx = 1, timer = 0, phase = "spawn", delay = tonumber(args and args.delay) or 3, results = {} }
  return "started: " .. #keys .. " configs of " .. model .. "; poll test_configs for progress, then the final per-config report.", false
end

M.schemas = {
  get_configs = {
    description = "List the config keys (.pc) available for a model (default: current player model). Use the keys with spawn.",
    inputSchema = { type = "object", properties = { model = { type = "string", description = "Model key, e.g. 'pickup' (default: current)" } } },
  },
  spawn = {
    description = "Spawn a vehicle. Default replaces the current vehicle with the given model+config; add=true spawns an additional one. model defaults to the current model; config defaults to the model default.",
    inputSchema = { type = "object", properties = {
      model = { type = "string", description = "Model key, e.g. 'pickup' (default: current)" },
      config = { type = "string", description = "Config key from get_configs, or a .pc path (default: model default)" },
      add = { type = "boolean", description = "Add an extra vehicle instead of replacing the current one (default false)" },
    } },
  },
  test_configs = {
    description = "Spawn-test every config of a model (default current): replaces the vehicle with each config, waits, and records error-log lines + physics instability. Long-running/async: call to start, poll for progress, then receive the final per-config report (config, ok, errors, unstable).",
    inputSchema = { type = "object", properties = {
      model = { type = "string", description = "Model key (default: current)" },
      delay = { type = "number", description = "Seconds to wait per config before checking (default 3)" },
    } },
  },
}

return M
