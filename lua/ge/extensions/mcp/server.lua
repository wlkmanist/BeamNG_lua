-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Minimal MCP (Model Context Protocol) server over Streamable HTTP.
-- The C++ WebWSServer parks each HTTP request and surfaces it here; this module
-- owns the whole JSON-RPC protocol. Point Cursor at http://127.0.0.1:29292/mcp
--   extensions.load('mcp_server')

local M = { dependencies = { 'mcp_tools' } }

-- Default 29292; the supervisor launches extra instances with -mcpport <n> so several
-- games can each expose their own MCP at once.
local function resolveMcpPort()
  local args = Engine.getStartingArgs()
  local idx = args and tableFindKey(args, '-mcpport')
  return (idx and tonumber(args[idx + 1])) or 29292
end

local BASE_PORT = resolveMcpPort()  -- requested port; we bind the next free one if it's taken
local PORT_TRIES = 20               -- consecutive ports to cycle through before wrapping
local PORT  = BASE_PORT
local ROUTE = "/mcp"
local PROTOCOL_VERSION = "2024-11-05"

local server = nil
local publishedPort = nil     -- last port we told C++ we're actually listening on
local watchdogTimer = 0       -- seconds since the last listener health check
local WATCHDOG_INTERVAL = 2   -- how often onUpdate verifies the listener is up

-- The bind is async, so the real port is only known once it succeeds. Tell C++ so the "?info" pipe
-- query (the supervisor's source of truth) reports the port we actually listen on, not the request.
local function publishPort(p)
  if publishedPort == p then return end
  publishedPort = p
  if Engine.setMcpPort then Engine.setMcpPort(p) end
  if p ~= 0 then log("I", "mcp_server", "MCP listening on http://127.0.0.1:" .. tostring(p) .. ROUTE) end
end

-- Tools live in the mcp_tools extension; this server is just protocol plumbing.
-- Every function on that module is a tool; M.schemas there carries optional metadata.
local function toolsModule() return extensions.mcp_tools or {} end

local function toolList()
  local mod = toolsModule()
  local schemas = mod.schemas or {}
  local list = {}
  for name, fn in pairs(mod) do
    -- skip extension lifecycle/event hooks (onUpdate, onInstabilityDetected, ...)
    if type(fn) == "function" and not name:match("^on%u") then
      local s = schemas[name] or {}
      list[#list + 1] = { name = name, description = s.description or "", inputSchema = s.inputSchema or { type = "object" } }
    end
  end
  return list
end

local function result(id, res) return { jsonrpc = "2.0", id = id, result = res } end
local function rpcError(id, code, msg) return { jsonrpc = "2.0", id = id, error = { code = code, message = msg } } end

local function dispatch(rpc)
  local m = rpc.method
  if m == "initialize" then
    return result(rpc.id, {
      protocolVersion = (rpc.params and rpc.params.protocolVersion) or PROTOCOL_VERSION,
      capabilities = { tools = { listChanged = false } },
      serverInfo = { name = "beamng-game", version = "1.0.0" },
    })
  elseif m == "tools/list" then
    return result(rpc.id, { tools = toolList() })
  elseif m == "tools/call" then
    local p = rpc.params or {}
    local fn = toolsModule()[p.name]
    if type(fn) ~= "function" then return rpcError(rpc.id, -32602, "unknown tool: " .. tostring(p.name)) end
    local ok, res, isErr = pcall(fn, p.arguments)
    if not ok then res, isErr = "tool crashed: " .. tostring(res), true end
    -- a tool may return an image as { data = <base64>, mimeType = "image/jpeg" }; otherwise text
    local content
    if type(res) == "table" and res.data and res.mimeType then
      content = { { type = "image", data = res.data, mimeType = res.mimeType } }
    else
      content = { { type = "text", text = tostring(res or "") } }
    end
    return result(rpc.id, { content = content, isError = isErr == true })
  elseif m == "ping" then
    return result(rpc.id, {})
  end
  return rpcError(rpc.id, -32601, "method not found: " .. tostring(m))
end

-- returns (responseBody, httpStatus). Notifications (no id) get an empty 202.
local function handleRpc(bodyText)
  local ok, msg = pcall(jsonDecode, bodyText)
  if not ok or type(msg) ~= "table" then
    return jsonEncode(rpcError(nil, -32700, "parse error")), 200
  end
  if msg[1] ~= nil then -- JSON-RPC batch
    local out = {}
    for _, one in ipairs(msg) do
      if type(one) == "table" and one.id ~= nil then out[#out + 1] = dispatch(one) end
    end
    if #out == 0 then return "", 202 end
    return jsonEncode(out), 200
  end
  if msg.id == nil then return "", 202 end
  return jsonEncode(dispatch(msg)), 200
end

local function startServer()
  watchdogTimer = 0  -- give a fresh server a full interval before the watchdog judges it
  if server then return end
  server = BNGWebWSServer.getOrCreate("127.0.0.1", PORT, "", "", "", false, false)
  if not server then log("E", "mcp_server", "failed to create MCP server on port " .. tostring(PORT)); return end
  server:enableHttpHandler(ROUTE)
  log("I", "mcp_server", "MCP server binding on http://127.0.0.1:" .. tostring(PORT) .. ROUTE)
end

local function onUpdate(dtReal)
  -- Watchdog: recreate the listener if it ever stops accepting connections (worker
  -- thread exit, or a failed bind when the game restarts while the old port is still
  -- held). Without it a single hiccup means ERR_CONNECTION_REFUSED until the extension
  -- is reloaded by hand. Interval-gated so a server still binding isn't torn down and a
  -- genuinely stuck port retries at ~0.5 Hz.
  watchdogTimer = watchdogTimer + (dtReal or 0)
  if watchdogTimer >= WATCHDOG_INTERVAL then
    watchdogTimer = 0
    if server and server:isListening() then
      publishPort(PORT)  -- bind confirmed; report the real port
    else
      -- Bind failed (port taken by another instance) or the listener died: drop it, move to the
      -- next port and retry. The supervisor re-learns the new port from the next "?info".
      log("W", "mcp_server", "MCP listener down on port " .. tostring(PORT) .. "; trying next port")
      if server then BNGWebWSServer.destroy(server); server = nil end
      publishPort(0)
      PORT = BASE_PORT + ((PORT - BASE_PORT + 1) % PORT_TRIES)
      startServer()
    end
  end

  if not server then return end
  for _, req in ipairs(server:getHttpRequests()) do
    if req.method == "POST" then
      local body, status = handleRpc(req.body)
      server:respondHttp(req.id, status, "application/json", body)
    else
      server:respondHttp(req.id, 405, "text/plain", "Method Not Allowed")
    end
  end
end

-- Keep loaded across level loads / game mode changes (mcp_tools is kept too as a dependency).
local function onInit() setExtensionUnloadMode(M, "manual") end

local function onExtensionLoaded() startServer() end

local function onExtensionUnloaded()
  if server then BNGWebWSServer.destroy(server); server = nil end
end

-- Survive a Lua reload (CTRL + L): the VM teardown destroys the server.
local function onSerialize() return { active = server ~= nil } end
local function onDeserialize(data) if data and data.active then startServer() end end

M.onInit              = onInit
M.onExtensionLoaded   = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate            = onUpdate
M.onSerialize         = onSerialize
M.onDeserialize       = onDeserialize

return M
