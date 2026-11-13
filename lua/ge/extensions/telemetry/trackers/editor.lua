-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY EDITOR TRACKER

  Tracks how long the world editor stays open, and which of its windows are opened.
  The track builder is tracked by the other gameplay tracker.

  Tool names only. The editor carries level and asset paths, none of which are reported.
]]

local M = {}
M.dependencies = {'telemetry_core'}

local editorOpen = false

local function onEditorActivated()
  if editorOpen then return end
  editorOpen = true
  extensions.telemetry_core.startActivity("editorActive")
end

local function onEditorDeactivated()
  if not editorOpen then return end
  editorOpen = false
  extensions.telemetry_core.endActivity("editorActive")
end

local function onEditorToolWindowOpened(toolName, entryPoint)
  extensions.telemetry_core.addEvent({
    name = "editorToolWindowOpened",
    toolName = toolName,
    entryPoint = entryPoint,
  })
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")
  if editor and editor.active then onEditorActivated() end
end

-- close the open activity, otherwise the last one has no duration
local function onExit()
  onEditorDeactivated()
end

M.onExtensionLoaded = onExtensionLoaded
M.onExit = onExit
-- a lua reload tears the trackers down without an onExit, so close the activities here too
M.onExtensionUnloaded = onExit

M.onEditorActivated = onEditorActivated
M.onEditorDeactivated = onEditorDeactivated
M.onEditorToolWindowOpened = onEditorToolWindowOpened

return M
