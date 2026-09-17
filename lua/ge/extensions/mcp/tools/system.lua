-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- System tools: run GE Lua, logs, reloads, render info, screenshots, files, extensions.

local shared = require('mcp/shared')
local M = {}

local logPos = nil -- byte offset already returned by get_logs
local screenshotCounter = 0
local pendingShotPath = nil -- real path of an in-flight screenshot_image capture

function M.run_lua(args)
  local code = args and args.code
  if type(code) ~= "string" then return "missing 'code' string argument", true end
  local chunk, err = loadstring(code, "@mcp_run_lua")
  if not chunk then return "compile error: " .. tostring(err), true end
  local ok, res = pcall(chunk)
  if not ok then return "error: " .. tostring(res), true end
  return tostring(res), false
end

function M.get_logs(args)
  if logPos == nil then
    -- first call: return the tail of the existing log, then track from EOF
    local data, size = shared.readLogFrom(0)
    if data == nil then return "could not open beamng.log", true end
    logPos = size
    local n = math.min(tonumber(args and args.lines) or 200, 5000)
    local lines = {}
    for line in (data .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
    local out = {}
    for i = math.max(1, #lines - n + 1), #lines do out[#out + 1] = lines[i] end
    return (#out > 0 and table.concat(out, "\n") or "(log empty)"), false
  end
  local data, size = shared.readLogFrom(logPos)
  if data == nil then return "could not open beamng.log", true end
  logPos = size
  return (data ~= "" and data or "(no new log lines)"), false
end

function M.reload_ui()
  if type(reloadUI) ~= "function" then return "reloadUI unavailable", true end
  reloadUI()
  return "UI (CEF) hard-reloaded, ignoring cache", false
end

-- Reload the whole GE Lua VM (CTRL+L). Deferred to next frame, so this response is sent first.
function M.reload_lua()
  if not (Lua and Lua.requestReload) then return "Lua:requestReload unavailable", true end
  Lua:requestReload()
  return "GE Lua reload requested; picks up GE Lua edits (incl. these tools). Reconnect the MCP if it drops.", false
end

function M.get_render_info()
  local R = Engine.Render
  return jsonEncode({
    adapterType = R and R.getAdapterType and R.getAdapterType(),
    available = R and R.isAvailable and R.isAvailable(),
    vulkanEnabled = Engine.getVulkanEnabled and Engine.getVulkanEnabled(),
    gpu = Engine.Platform and Engine.Platform.getGPUInfo and Engine.Platform.getGPUInfo(),
  }), false
end

function M.screenshot(args)
  if type(createScreenshot2) ~= "function" then return "screenshots unavailable", true end
  local dir = "screenshots/mcp/"
  if not FS:directoryExists(dir) then FS:directoryCreate(dir, true) end
  screenshotCounter = screenshotCounter + 1
  local jpg = args and args.jpg == true
  local rel = dir .. "shot_" .. os.date("%Y%m%d_%H%M%S") .. "_" .. screenshotCounter .. (jpg and ".jpg" or ".png")
  local id = createScreenshot2({ filename = (rel:gsub("%.%w+$", "")), writeJPG = jpg, superSampling = 1 })
  if not id or id == 0 then return "screenshot failed (no graphics device?)", true end
  -- written asynchronously under the user path; ready within a few frames (before the AI reads it)
  return (FS:getUserPath() .. rel):gsub("\\", "/"), false
end

-- Take a small JPG and return it over the wire as a base64 image (no file read needed).
-- Async (capture is deferred): first call triggers it, call again in a moment to receive the image.
function M.screenshot_image(args)
  if pendingShotPath then
    local f = io.open(pendingShotPath, "rb")
    if not f then return "still capturing; call screenshot_image again in a moment", false end
    local bytes = f:read("*all"); f:close()
    pendingShotPath = nil
    return { data = (require('mime').b64(bytes)), mimeType = "image/jpeg" }, false
  end
  if type(createScreenshot2) ~= "function" then return "screenshots unavailable", true end
  local dir = "screenshots/mcp/"
  if not FS:directoryExists(dir) then FS:directoryCreate(dir, true) end
  local rel = dir .. "wire_" .. os.time() .. "_" .. screenshotCounter .. ".jpg"
  screenshotCounter = screenshotCounter + 1
  local scale = tonumber(args and args.scale) or 0.4
  local id = createScreenshot2({ filename = (rel:gsub("%.jpg$", "")), writeJPG = true, superSampling = 1, rescaleFactor = scale })
  if not id or id == 0 then return "screenshot failed (no graphics device?)", true end
  pendingShotPath = rel -- CWD-relative; Lua io.open is sandboxed to relative paths
  return "capturing JPG (scale " .. scale .. "); call screenshot_image again in a moment to receive the image", false
end

function M.file_info(args)
  local p = args and args.path
  if type(p) ~= "string" or p == "" then return "missing 'path'", true end
  local out = {
    path = p,
    exists = FS:fileExists(p),
    isDir = FS:directoryExists(p),
    realPath = FS:getFileRealPath(p), -- vfs -> real (empty if not found)
    virtualPath = FS:native2Virtual(p), -- real -> vfs
    expanded = FS:expandFilename(p),
  }
  local st = FS:stat(p)
  if st and st.filetype then out.stat = st end
  return jsonEncode(out), false
end

-- Load and execute a Lua file in the GE VM (resolves a VFS path to its real path).
function M.load_file(args)
  local p = args and args.path
  if type(p) ~= "string" or p == "" then return "missing 'path'", true end
  local real = FS:getFileRealPath(p)
  if real == "" then real = p end
  local chunk, err = loadfile(real)
  if not chunk then return "load error: " .. tostring(err), true end
  local ok, res = pcall(chunk)
  if not ok then return "exec error: " .. tostring(res), true end
  return "loaded " .. p .. (res ~= nil and (" -> " .. tostring(res)) or ""), false
end

function M.load_extension(args)
  local name = args and args.name
  if type(name) ~= "string" then return "missing 'name'", true end
  extensions.load(name)
  return (extensions.isExtensionLoaded(name) and "loaded " or "load failed for ") .. name, false
end

function M.unload_extension(args)
  local name = args and args.name
  if type(name) ~= "string" then return "missing 'name'", true end
  if name == "mcp_server" or name == "mcp_tools" then return "refusing to unload " .. name .. " (would kill this MCP server)", true end
  extensions.unload(name)
  return "unloaded " .. name, false
end

-- Engine/preference variable (VariableRegistry), e.g. $pref::Video::gpu, $CEF_UI::maxSizeHeight.
function M.get_var(args)
  local name = args and args.name
  if type(name) ~= "string" or name == "" then return "missing 'name'", true end
  return tostring(VariableRegistry.get(name, args.default ~= nil and tostring(args.default) or "")), false
end

function M.set_var(args)
  local name = args and args.name
  if type(name) ~= "string" or name == "" then return "missing 'name'", true end
  if args.value == nil then return "missing 'value'", true end
  VariableRegistry.set(name, args.value)
  return name .. " = " .. tostring(VariableRegistry.get(name, "")), false
end

M.schemas = {
  run_lua = {
    description = "Run a Lua string in the game engine (GE) Lua VM and return tostring() of its result.",
    inputSchema = { type = "object", properties = { code = { type = "string", description = "Lua source to execute" } }, required = { "code" } },
  },
  get_logs = {
    description = "Game log (beamng.log): the FIRST call returns the last N lines; subsequent calls return only lines logged since the previous call.",
    inputSchema = { type = "object", properties = { lines = { type = "integer", description = "Tail size for the first call (default 200, max 5000)" } } },
  },
  reload_ui = { description = "Hard-reload the UI (CEF), ignoring cache. Use after editing UI files." },
  reload_lua = { description = "Reload the game-engine (GE) Lua VM (equivalent to CTRL+L). Picks up GE Lua edits including these MCP tools. The MCP may briefly drop; reconnect if so." },
  get_render_info = { description = "Render backend info as JSON: graphics adapter type, Vulkan enabled, availability, and GPU info." },
  screenshot = {
    description = "Take a screenshot and return its absolute file path (so it can be opened/viewed). Saved under screenshots/mcp/.",
    inputSchema = { type = "object", properties = { jpg = { type = "boolean", description = "Save as JPG instead of PNG (default false)" } } },
  },
  screenshot_image = {
    description = "Take a small JPG and return it inline as a base64 image over the wire (no file read needed) for quick visual assessment. Async: call once to trigger, call again in a moment to receive the image.",
    inputSchema = { type = "object", properties = { scale = { type = "number", description = "Resolution scale 0..1 (default 0.4; smaller = faster/lighter)" } } },
  },
  file_info = {
    description = "Info for a path: exists, isDir, realPath (VFS->real), virtualPath (real->VFS), expanded, and stat (filesize, modtime, filetype).",
    inputSchema = { type = "object", properties = { path = { type = "string", description = "A VFS path (e.g. /vehicles/pickup/pickup.jbeam) or a real OS path" } }, required = { "path" } },
  },
  load_file = {
    description = "Load and execute a Lua file in the GE VM by path (VFS or real). Returns its result or the error.",
    inputSchema = { type = "object", properties = { path = { type = "string", description = "Path to a .lua file" } }, required = { "path" } },
  },
  load_extension = {
    description = "Load a GE extension by name (e.g. 'core_camera', 'util_richPresence').",
    inputSchema = { type = "object", properties = { name = { type = "string", description = "Extension name (underscore form)" } }, required = { "name" } },
  },
  unload_extension = {
    description = "Unload a GE extension by name (mcp_server/mcp_tools are protected).",
    inputSchema = { type = "object", properties = { name = { type = "string", description = "Extension name (underscore form)" } }, required = { "name" } },
  },
  get_var = {
    description = "Read an engine/preference variable (VariableRegistry), e.g. '$pref::Video::gpu'.",
    inputSchema = { type = "object", properties = {
      name = { type = "string", description = "Variable name (e.g. $pref::...)" },
      default = { description = "Default if unset (default '')" },
    }, required = { "name" } },
  },
  set_var = {
    description = "Set an engine/preference variable (VariableRegistry). Returns the read-back value.",
    inputSchema = { type = "object", properties = {
      name = { type = "string", description = "Variable name (e.g. $pref::...)" },
      value = { description = "New value (string/number/bool)" },
    }, required = { "name", "value" } },
  },
}

return M
