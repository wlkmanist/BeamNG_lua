-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Input tools: inject control events, hydro up/down test, run Lua in vehicle VMs.

local shared = require('mcp/shared')
local M = {}

local hydroTest = nil -- input up->down->neutral sequence, then scan log for errors

-- Build a vehicle-VM snippet that runs `code`, captures its result/error, and
-- reports it back to GE as _cb.vehLua(vehicleId, resultString).
local function vehRunnerCmd(code)
  return "local f,e=loadstring(" .. string.format("%q", code) ..
    [[,"@mcp_veh") local r if not f then r="compile error: "..tostring(e) else local ok,res=pcall(f) r=ok and tostring(res) or ("error: "..tostring(res)) end obj:queueGameEngineLua("extensions.mcp_tools._cb.vehLua("..obj:getId()..","..string.format("%q", r)..")") ]]
end

M.cb = {
  vehLua = function(vid, result)
    shared.asyncResults.vehLua = shared.asyncResults.vehLua or {}
    shared.asyncResults.vehLua[tostring(vid)] = result
  end,
}

function M.onUpdate(dtReal)
  local t = hydroTest
  if not t then return end
  t.timer = t.timer + (dtReal or 0)
  if t.step == 1 and t.timer > 0.6 then
    be:queueObjectLua(t.vid, string.format("input.event(%q, -1, 2)", t.event)); t.step, t.timer = 2, 0
  elseif t.step == 2 and t.timer > 0.6 then
    be:queueObjectLua(t.vid, string.format("input.event(%q, 0, 2)", t.event)); t.step, t.timer = 3, 0
  elseif t.step == 3 and t.timer > 0.3 then
    local data = shared.readLogFrom(t.logPos) or ""
    local errs = {}
    for line in (data .. "\n"):gmatch("(.-)\r?\n") do if line:find("|E|", 1, true) then errs[#errs + 1] = line end end
    shared.asyncResults.hydro = { event = t.event, vid = t.vid, ok = (#errs == 0), errors = errs }
    hydroTest = nil
  end
end

function M.inject_input(args)
  local event = args and args.event
  if type(event) ~= "string" then return "missing 'event' (e.g. 'steering','throttle','brake','parkingbrake','clutch')", true end
  local value = tonumber(args and args.value) or 0
  local filter = tonumber(args and args.filter) or 2 -- FILTER_DIRECT
  local vid = shared.argVehId(args)
  if not getObjectByID(vid) then return "no vehicle " .. tostring(vid), true end
  be:queueObjectLua(vid, string.format("input.event(%q, %s, %s)", event, value, filter))
  return string.format("sent input.event(%s, %s, filter=%s) to vehicle %d", event, value, filter, vid), false
end

function M.test_hydro(args)
  local prev = shared.asyncResults.hydro
  local vid = shared.argVehId(args)
  if not getObjectByID(vid) then return "no vehicle " .. tostring(vid), true end
  local event = (args and args.event) or "steering"
  local _, pos = shared.readLogFrom(nil) -- current log EOF
  hydroTest = { vid = vid, event = event, step = 1, timer = 0, logPos = pos }
  be:queueObjectLua(vid, string.format("input.event(%q, 1, 2)", event)) -- up
  if prev then shared.asyncResults.hydro = nil; return jsonEncode(prev), false end
  return "hydro test started (event='" .. event .. "', vehicle " .. vid .. "); call again in ~2s for the result", false
end

function M.run_lua_vehicle(args)
  local code = args and args.code
  if type(code) ~= "string" then return "missing 'code' string argument", true end
  local cmd = vehRunnerCmd(code)
  local prev = shared.asyncResults.vehLua
  if args and args.all then
    shared.asyncResults.vehLua = {}
    be:queueAllObjectLua(cmd)
  else
    local vid = shared.argVehId(args)
    if not getObjectByID(vid) then return "no vehicle " .. tostring(vid), true end
    shared.asyncResults.vehLua = {}
    be:queueObjectLua(vid, cmd)
  end
  if prev and next(prev) then return jsonEncode(prev), false end
  return "queued in vehicle VM(s); call again in a moment for results", false
end

M.schemas = {
  inject_input = {
    description = "Inject a vehicle input event (control) into a vehicle's Lua VM, e.g. steering/throttle/brake or a vehicle-specific event.",
    inputSchema = { type = "object", properties = {
      event = { type = "string", description = "Input event name (steering, throttle, brake, parkingbrake, clutch, ...)" },
      value = { type = "number", description = "Value, typically -1..1 (steering) or 0..1" },
      filter = { type = "integer", description = "Input filter (default 2 = FILTER_DIRECT)" },
      id = shared.vehIdProp.id,
    }, required = { "event" } },
  },
  test_hydro = {
    description = "Drive an input up -> down -> neutral over ~1.5s and report any errors logged during that window. Async: call again after ~2s to get the result.",
    inputSchema = { type = "object", properties = {
      event = { type = "string", description = "Input event to exercise (default 'steering')" },
      id = shared.vehIdProp.id,
    } },
  },
  run_lua_vehicle = {
    description = "Run a Lua string in a vehicle's Lua VM (default: player vehicle; set all=true for every spawned vehicle). Async: returns the PREVIOUS run's results as a JSON map of vehicleId -> result; call again to get the latest.",
    inputSchema = { type = "object", properties = {
      code = { type = "string", description = "Lua source to execute in the vehicle VM" },
      id = shared.vehIdProp.id,
      all = { type = "boolean", description = "Run in all spawned vehicles instead of one" },
    }, required = { "code" } },
  },
}

return M
