-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Performance tools: frame metrics, FPS-limiter reason, GPU memory.

local M = {}

function M.get_performance_metrics()
  local m = {}
  if Engine.Debug and Engine.Debug.getLastPerformanceMetrics then
    Engine.Debug.getLastPerformanceMetrics(m)
  end
  return jsonEncode(m), false
end

function M.get_fps_limit_reason()
  if type(Engine.getCurrentFpsLimitReason) ~= "function" then return "getCurrentFpsLimitReason unavailable", true end
  return jsonEncode(Engine.getCurrentFpsLimitReason()), false
end

function M.get_vram_usage()
  local R = Engine.Render
  if not (R and R.getVRAMUsage) then return "getVRAMUsage unavailable", true end
  local v = R.getVRAMUsage()
  return (type(v) == "table" and jsonEncode(v) or tostring(v)), false
end

local capturing = false

-- Captures are kept in <userFolder>/optick/, named so they sort chronologically (we need
-- them later, never temp). An absolute drive/UNC path is respected as-is; a relative path or
-- bare filename lands under <userFolder>/optick/.
local function resolveCapturePath(p)
  if type(p) == "string" and (p:match("^%a:[/\\]") or p:match("^[/\\][/\\]")) then
    return (p:gsub("\\", "/"))
  end
  local rel
  if type(p) == "string" and p ~= "" then
    rel = "optick/" .. p:gsub("\\", "/"):gsub("^/+", ""):gsub("^optick/", "")
  else
    rel = "optick/optick_" .. os.date("%Y-%m-%d_%H-%M-%S") .. ".opt"
  end
  local dir = rel:match("^(.*)/[^/]+$")
  if dir then FS:directoryCreate(dir, true) end
  return ((FS:getUserPath() .. rel):gsub("\\", "/"))
end

-- Trigger an Optick capture for `duration` seconds (after optional `delay`) and save a .opt.
-- Non-blocking: a jobsystem coroutine sleeps while the game keeps running, so the agent
-- should reproduce the slow case during the window, then analyze the saved file.
function M.profiler_run(args)
  if not (Engine.Profiler and Engine.Profiler.startCapture and Engine.Profiler.saveCapture) then
    return "Engine.Profiler not available (this build lacks BNG_PROFILER=OPTICK)", true
  end
  if capturing then
    return "a profiler capture is already running", true
  end

  args = args or {}
  local duration = tonumber(args.duration) or 5
  if duration <= 0 then return "'duration' must be > 0 seconds", true end
  local delay = math.max(0, tonumber(args.delay) or 0)
  local path = resolveCapturePath(args.path)
  if not path or path == "" then return "could not resolve capture path", true end

  capturing = true
  local job = core_jobsystem.create(function(j)
    if delay > 0 then j.sleep(delay) end
    Engine.Profiler.startCapture()
    j.sleep(duration)
    Engine.Profiler.stopCapture()
    Engine.Profiler.saveCapture(path)
    log("I", "mcp.perf", "profiler_run saved: " .. path)
  end, 0.1)
  if job and job.setExitCallback then job.setExitCallback(function() capturing = false end) else capturing = false end

  return jsonEncode({
    ok = true,
    path = path,
    duration = duration,
    delay = delay,
    readyInSeconds = delay + duration,
    note = "Capture running; the .opt is written when it finishes. Wait readyInSeconds, then analyze with DevTools/optick/optick.py or open it via the optick-ui MCP."
  }), false
end

-- Launch the external Optick GUI - same as the CTRL+ALT+O keybind (the launch_optick debug action).
function M.run_optick_ui()
  if launchOptick then launchOptick() end
  return jsonEncode({ ok = true }), false
end

M.schemas = {
  get_performance_metrics = { description = "Last frame's performance metrics (frame timings, memory, counts) as JSON." },
  get_fps_limit_reason = { description = "Current FPS-limiter sources and caps (vsync, foreground/background limits, focus) as JSON." },
  get_vram_usage = { description = "GPU VRAM usage as JSON." },
  profiler_run = {
    description = "Trigger an Optick profiler capture (BNG_PROFILER=OPTICK builds only). Captures for 'duration' seconds after an optional 'delay', saves a .opt file and returns its path. Non-blocking - the game keeps running, so reproduce the slow case during the window; the file is ready after delay+duration seconds, then analyze it with DevTools/optick/optick.py or open it via the optick-ui MCP.",
    inputSchema = { type = "object", properties = {
      duration = { type = "number", description = "Capture length in seconds (default 5)" },
      delay = { type = "number", description = "Seconds to wait before starting the capture (default 0)" },
      path = { type = "string", description = "Output .opt path. Default: <userFolder>/optick/optick_<date>.opt. A relative path or bare filename is placed under <userFolder>/optick/; an absolute drive/UNC path is used as-is." },
    } },
  },
  run_optick_ui = {
    description = "Launch the external Optick profiler GUI - same as the CTRL+ALT+O keybind (non-shipping Optick builds only).",
  },
}

return M
