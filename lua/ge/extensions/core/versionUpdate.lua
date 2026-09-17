-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.lastVersion = nil

local function getMajorVersion(version)
  return string.match(version or "", "^(%d+%.%d+)")
end

local function onExtensionLoaded()
  local newInstall = settings.getValue('onlineFeatures') == "ask"
  local lastVersion = settings.getValue('lastVersion')
  local folderCleanupRequested = settings.getValue('folderCleanupRequested')
  if folderCleanupRequested then
    log("D", "", "Manual folder cleanup requested")
  end
  --newInstall = true                              -- fake new install
  --newInstall = nil; lastVersion = "0.1.2.3.fake" -- fake major update
  --settings.setValue('disableModsAfterUpdate',nil)-- use together with above line, to simulate a clean major update
  --newInstall = nil; lastVersion = beamng_version -- fake no update
  local currentMajor = getMajorVersion(beamng_version)
  local lastMajor = getMajorVersion(lastVersion)
  log("D", "", string.format("Current version: '%s' ('%s'), last version: '%s' ('%s'), newInstall: '%s'", dumps(beamng_version), dumps(currentMajor), dumps(lastVersion), dumps(lastMajor), dumps(newInstall)))
  if newInstall or (currentMajor == lastMajor) then
    if folderCleanupRequested then
      log("D", "", "Manual folder cleanup running now...")
      FS:folderCleanup("")
    else
      log("D", "", "Folder cleanup skipped")
    end
    return
  end
  M.lastVersion = lastVersion or "0.0.0.0.unknown_before_0.38"
  M.updateBackupPath = FS:folderCleanup(M.lastVersion)
  log("I", "", string.format("Folder cleanup done. Destination backup path: %s", dumps(M.updateBackupPath)))
end

local countdownWorkaround = 2
local function onUpdate()
  countdownWorkaround = countdownWorkaround - 1
  if countdownWorkaround > 0 then return end  -- hack so that settings.setValue works correctly (value would get overwritten with old data otherwise, due to bug in settings system)
  M.onUpdate = nil
  extensions.hookUpdate("onUpdate")
  log("D", "", string.format("Saving lastVersion to disk: %s", dumps(beamng_version)))
  settings.setValue('lastVersion', beamng_version)
  settings.setValue('folderCleanupRequested', nil)
end

M.updatedFromVersion = function() return M.lastVersion end
M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
return M
