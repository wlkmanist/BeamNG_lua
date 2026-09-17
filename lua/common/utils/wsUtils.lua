-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- various tools for libWebsocket

local M = {}

local function generateRandomData(size)
  local chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  local res = {}
  for i = 1, size do
    local n = math.random(1, #chars)
    res[i] = chars:sub(n, n)
  end
  return table.concat(res)
end

-- Round-trip probe: spin up a throwaway client against `serverAddr`, send a magic
-- string, and confirm the server received it and a reply makes it back. Proves the
-- adapter is actually reachable (not merely present). Returns false on any failure.
--
-- Guards against the two ways this used to crash:
--   - sandbox refusing the client: getOrCreate returns nil for a non-loopback
--     address under the network sandbox (webClient.cpp), so we bail on nil. The
--     caller also skips probing entirely while the sandbox is on.
--   - racing the server's lws worker thread: the server is serviced by its own
--     thread (webServer.cpp), so we only pump the *client* and read the server's
--     mutex-protected event queue here — never server:update().
local function testWSConnection(server, serverAddr, port, path, protocol)
  local client = BNGWSClient.getOrCreate(serverAddr, port, path, protocol)
  if not client then return false end

  local magicUp = generateRandomData(32)
  local magicDown = generateRandomData(32)
  client:sendData(magicUp)

  -- Up: pump the client until the server reports our magic, then echo magicDown.
  local gotUp = false
  for _ = 1, 20 do
    client:update()
    for _, e in ipairs(server:getPeerEvents()) do
      if e.type == 'D' and e.msg == magicUp then
        server:sendData(e.peerId, magicDown)
        gotUp = true
        break
      end
    end
    if gotUp then break end
  end
  if not gotUp then BNGWSClient.destroy(client); return false end

  -- Down: pump the client until the echo arrives.
  local gotDown = false
  for _ = 1, 20 do
    client:update()
    for _, e in ipairs(client:getPeerEvents()) do
      if e.type == 'D' and e.msg == magicDown then gotDown = true; break end
    end
    if gotDown then break end
  end
  BNGWSClient.destroy(client)
  return gotDown
end

-- Address clients should use to reach `server`. Only meaningful for a LAN bind
-- ("0.0.0.0"/"any") with the network sandbox off (otherwise the bind is forced to
-- 127.0.0.1, so "localhost"). Probes each real adapter and returns the first that
-- round-trips; falls back to the first real IPv4, else "localhost".
local function chooseAddress(server, listenAddr, port, protocolName)
  if listenAddr ~= '0.0.0.0' and listenAddr ~= 'any' then return 'localhost' end
  -- Only the network sandbox forces localhost. The Sandbox.Network API only exists on
  -- tech/Aegis builds, so a missing API means "no sandbox" -> keep probing adapters.
  local net = Engine and Engine.Sandbox and Engine.Sandbox.Network
  if net and net.isEnabled() then return 'localhost' end

  local fallback
  for _, addr in ipairs(BNGWebWSServer.getNetworkAdapterAddresses()) do
    local desc = (addr.description or ''):lower()
    local ip = addr.ipv4Addr
    if ip and ip ~= '' and not (desc:find('virtualbox') or desc:find('vmware')) then
      fallback = fallback or ip
      -- pcall so a probe failure can never take down server startup; on error or
      -- a non-verifying adapter we just move on.
      local ok, verified = pcall(testWSConnection, server, ip, port, '/', protocolName)
      if ok and verified then return ip end
    end
  end
  return fallback or 'localhost'
end

local function createOrGetWS(listenAddr, port, path, protocolName, redirPage, enableDataStreams, useTLS)
  local server = BNGWebWSServer.getOrCreate(listenAddr, port, path, protocolName, redirPage, false, useTLS == true)
  local chosenAddress = chooseAddress(server, listenAddr, port, protocolName)
  if enableDataStreams == nil then
    enableDataStreams = true
  end
  if enableDataStreams then
    server:enableDataStreams()
  end
  return server, chosenAddress
end


M.createOrGetWS = createOrGetWS

return M
