-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- this module is used to execute asnc tasks that are put upon us.
-- i.e. protocol scheme commands

local M = {}

local logTag = 'commandhandler'
local uiReady = false
local cachedSchemes = {}
local ignoreStartupCmd = false --GE reload will reexecute

local hex_to_char = function(x)
  return string.char(tonumber(x, 16))
end

local unescape = function(url)
  return url:gsub("%%(%x%x)", hex_to_char)
end

-- Surface a runRepro failure (rejection, missing bat, ...) in a console window
-- that stays open so the user can read what went wrong. The reason and command
-- are untrusted, so they are written to a file with writeFile (no shell) and
-- shown with `type` (which never interprets the file's contents) — the only
-- thing handed to the shell is a controlled file path, so there is no injection
-- surface. pcall-guarded: on shipping builds executeShell is absent and this
-- no-ops cleanly.
local function notifyReproFailure(reason, command)
  local relPath = "repro_rejected.txt"
  local msg = "BeamNG repro command NOT run.\r\n\r\nReason: " .. tostring(reason)
      .. "\r\nCommand: " .. tostring(command) .. "\r\n"
  writeFile(relPath, msg)
  local realPath = FS:getFileRealPath(relPath)
  if realPath == "" then return end
  -- `start "title"` consumes the title token; the /k string starts with `type`
  -- (not a quote), so cmd keeps the path quotes intact even with spaces in it.
  pcall(function() executeShell("cmd.exe", '/c start "Repro rejected" cmd /k type "' .. realPath .. '"') end)
end

-- scheme commands come in as beamng:v1/startToolchainServer

local function onSchemeCommand(scheme, isStartingArg)
  log('D', logTag, 'new scheme command: ' .. tostring(scheme))
  if not uiReady then
    table.insert(cachedSchemes, {sc = scheme, startArg = isStartingArg} )
    return
  end
  scheme = unescape(scheme) -- "%20" -> " "
  local args = split(scheme, '/', 2)
  if #args < 2  then
    log('E', 'scheme', 'invalid/unsupported starting command: ' .. dumps(args))
    return
  end

  log('D', 'scheme', "invoked by scheme: " .. tostring(scheme) .. ' = ' .. dumps(args))

  local version = args[1]
  local cmd     = args[2]
  local data    = args[3]

  --log('E', 'scheme', ' === === === === === === === === ===')
  --dump(args)

  if cmd == 'showMod' and version == 'v1' then
    -- args = { "v1", "subscriptionMod", "MKA5UZHYS/6902/spanishpoliceroamerpack.zip" }
    local filename = split(data, '/')
    filename = filename[#filename]
    log('I', logTag, 'show mod: ' .. tostring(data))
    extensions.core_repository.uiShowMod(data)
    return
  elseif cmd == 'subscriptionMod' and version == 'v1' then
    -- args = { "v1", "subscriptionMod", "MKA5UZHYS/6902/spanishpoliceroamerpack.zip" }
    local filename = split(data, '/')
    filename = filename[#filename]
    log('I', logTag, 'subscription mod: ' .. tostring(data))
    extensions.core_repository.uiShowRepo()
    extensions.core_repository.modSubscribe(data)
    return
  elseif cmd == 'downloadMod' and version == 'v1' then
    -- args = { "v1", "downloadMod", "MKA5UZHYS/6902/spanishpoliceroamerpack.zip" }
    local filename = split(data, '/')
    filename = filename[#filename]
    log('I', logTag, 'downloading mod: ' .. tostring(data))
    extensions.core_repository.installMod(data, filename, 'mods/repo/')
    return
  elseif cmd == "updateZipMod" and version == "v1" then
    -- args = { "v1", "updateZipMod", "crepe.zip", "crepe.zip.tmp" }
    local tmp = split(data, '/')
    if #tmp < 2 then
      log("E","commandhandler","Wrong argument count!")
      return
    end
    log('I', logTag, "updateZipMod '" .. tostring(tmp[1]).. "' with new '"..tostring(tmp[2]) .."'")
    extensions.core_modmanager.updateZipMod(tmp[1], tmp[2])
    return
  elseif cmd == "openMap" and version == "v1" then
    -- args = { "v1", "openMap", "levels/gridmap/info.json" }
    local jsondata = jsonDecode(data, nil)
    -- if core_loadMapCmd then extensions.unload("core_loadMapCmd") end --if we are already going somewhere, remove previous 'queued' commands
    extensions.load("core_loadMapCmd")
    setExtensionUnloadMode("core_loadMapCmd", "manual")
    core_loadMapCmd.set(jsondata, isStartingArg)
    return
  elseif cmd == "loadSnapshot" and version == "v1" then
    extensions.load("core_snapshot")
    setExtensionUnloadMode("core_snapshot", "manual")
    core_snapshot.onSnapshotSchemeCommand(cmd, data, isStartingArg)
    return
  elseif cmd == "tech_utils" and version == "v1" then
    log("I", "", "Received commandHandler request for "..dumps(cmd)..": "..dumps(data))
    local functionName = data
    if type(extensions[cmd][functionName]) == "function" then
      extensions[cmd][functionName]()
    else
      log("E", "", "Couldn't run "..cmd.."."..functionName.."(): not a function")
    end
    return
  elseif cmd == "core_input_actions" and version == "v1" then
    -- for example using the URL like this:  beamng:v1/core_input_actions/triggerDownUp/toggleCamera
    log("I", "", "Received commandHandler request for "..dumps(cmd)..": "..dumps(data))
    local params = split(data, "/")
    local functionName = table.remove(params, 1)
    if type(extensions[cmd][functionName]) == "function" then
      extensions[cmd][functionName](unpack(params))
    else
      log("E", "", "Couldn't run "..cmd.."."..functionName.."(): not a function")
    end
    return
  elseif cmd == "startToolchainServer" then
    extensions.load('networking_editorToolchain')
    return
  elseif cmd == "startWorkbenchServer" then
    -- Same path as the QR toggle: always bind LAN (0.0.0.0). activate() is idempotent,
    -- so the SPA reissuing this on every reconnect never drops live peers.
    if not FS:fileExists('/lua/ge/extensions/workbench/webSocketHandler.lua') then return end -- may be filtered out on release
    extensions.load('workbench_webSocketHandler')
    workbench_webSocketHandler.activate()
    return
  elseif cmd == "startDebugServer" then
    startDebugServer()
    return
  elseif cmd == "stopDebugServer" then
    stopDebugServer()
    return
  elseif cmd == "attachDebugger" then
    if not isDebuggerAttached() then
      log('I', 'debugger', 'Debugger attaching ...')
      attachDebugger()
    else
      log('I', 'debugger', 'Debugger already attached.')
    end
    return
  elseif cmd == "detachDebugger" then
    if isDebuggerAttached() then
      detachDebugger()
      log('I', 'debugger', 'Debugger detaching ...')
    end
    return
  elseif cmd == "openTestViewer" and version == "v1" then
    -- Open the local microviewer (game/test-viewer.html) in the default browser.
    -- NOTE: openWebBrowser() is blocked by CEF's URL domain filter for file://
    -- URLs ("unable to open webpage due to domain filter"), so we shell-open the
    -- file via `start` instead. This makes openTestViewer dev-only, like runRepro
    -- (executeShell is #if !defined(BNG_SHIPPING)) — acceptable since shipping
    -- builds have no test-viewer.html.
    local realPath = FS:getFileRealPath("test-viewer.html")
    if realPath == "" then
      log('E', logTag, 'openTestViewer: test-viewer.html not found at game root')
      return
    end
    log('I', logTag, 'openTestViewer: ' .. realPath)
    -- `start "" "<path>"` opens the file with its default handler (browser) and
    -- returns immediately, so executeShell's blocking wait resolves at once.
    local ok = pcall(function() executeShell("cmd.exe", '/c start "" "' .. realPath .. '"') end)
    if not ok then
      log('W', logTag, 'openTestViewer unsupported on this build (executeShell unavailable)')
      return
    end
    -- If the game was booted solely to service this scheme command (fresh launch
    -- with no prior instance), quit now so we don't leave an idle game running.
    -- When an instance was already running (pipe path), isStartingArg is false and
    -- we leave the user's session untouched.
    if isStartingArg then shutdown(0) end
    return
  elseif cmd == "runRepro" and version == "v1" then
    -- `data` is ALREADY URL-decoded: onSchemeCommand ran unescape(scheme) before
    -- the split above, so do NOT unescape again. `data` holds the full command
    -- line (embedded '/' and spaces preserved).
    local command = data
    -- On every early return below, a fresh-launch instance (booted solely to
    -- service this scheme command) self-closes so it never lingers idle; the
    -- pipe path (pre-existing game, isStartingArg false) is left untouched.
    if not command or command == "" then
      log('E', logTag, 'runRepro: empty command')
      if isStartingArg then shutdown(0) end
      return
    end
    extensions.load("core_reproGuard")
    local allowed, reason = core_reproGuard.isCommandAllowed(command)
    if not allowed then
      log('E', logTag, 'runRepro rejected (' .. tostring(reason) .. '): ' .. tostring(command))
      notifyReproFailure(reason, command)
      if isStartingArg then shutdown(0) end
      return
    end
    local bat = FS:getFileRealPath("run_repro.bat")
    if bat == "" then
      log('E', logTag, 'runRepro: run_repro.bat not found at game root')
      notifyReproFailure('run_repro.bat not found at game root', command)
      if isStartingArg then shutdown(0) end
      return
    end
    -- Launch detached + visible so the game thread never blocks on executeShell's
    -- hidden, INFINITE-wait behavior. `start "Repro"` consumes the title so a
    -- space in the bat path is safe; the command has no shell metacharacters
    -- (guaranteed by the guard) so it can follow unquoted as cmd /k's args.
    local shellArgs = '/c start "Repro" cmd /k "' .. bat .. '" ' .. command
    -- executeShell is #if !defined(BNG_SHIPPING); on shipping the global is
    -- absent and pcall fails cleanly.
    local ok = pcall(function() executeShell("cmd.exe", shellArgs) end)
    if not ok then
      log('W', logTag, 'runRepro unsupported on this build (executeShell unavailable)')
      if isStartingArg then shutdown(0) end
      return
    end
    log('I', logTag, 'runRepro launched: ' .. command)
    -- Fresh-launch instance has done its job (run_repro.bat runs in its own
    -- console); quit so we don't leave an idle game behind. A pre-existing
    -- instance (pipe path, isStartingArg false) keeps running.
    if isStartingArg then shutdown(0) end
    return
  end

  log('E', 'scheme', 'unsupported scheme command: ' .. dumps(args))
end

local function onUiReady()
  uiReady = true
  for k, v in pairs(cachedSchemes) do
    onSchemeCommand(v.sc, v.startArg)
  end
  cachedSchemes = {}
end

local function onFirstUpdate()
  if ignoreStartupCmd then
    log('D', logTag, 'module reloaded: Startup command ignored')
    return
  end
  local cmdArgs = Engine.getStartingArgs()
  for i = 1, #cmdArgs do
    local arg = cmdArgs[i]
    arg = arg:stripcharsFrontBack('"')
    if arg == '-command' and i + 1 <= #cmdArgs then
      local arg1 = cmdArgs[i + 1]
      if arg1 then
      arg1 = arg1:stripcharsFrontBack('"\'')
      if arg1:startswith('beamng:') then
        onSchemeCommand(arg1:sub(8), true) -- strip 'beamng:'
        break
      else
        log('E', logTag, 'unknown scheme: ' ..tostring(arg1))
      end
      end
    end
  end
end

local function onSerialize()
  return {ignoreStartupCmd = true}
end

local function onDeserialized(d)
  ignoreStartupCmd = d.ignoreStartupCmd or false
end


-- public interface
M.onExtensionLoaded = nop--onExtensionLoaded
M.onSchemeCommand = onSchemeCommand
M.onFirstUpdate = onFirstUpdate
M.onUiReady = onUiReady
M.onSerialize         = onSerialize
M.onDeserialized      = onDeserialized

return M
