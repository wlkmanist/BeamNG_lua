-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
USER IDENTITY & ANONYMOUS TELEMETRY MODULE

WHAT THIS DOES:
This module creates and manages an anonymous user identifier for telemetry data collection.
Think of it like giving you a unique but anonymous badge number instead of using your real name.

WHY WE DO THIS:
- BeamNG collects usage statistics to improve the game (like crash reports, feature usage, etc.)
- We want to track patterns without knowing who you are personally
- This protects your privacy while still helping us make the game better

HOW IT WORKS:
1. Creates a random "salt" value (like a secret code) and saves it to a file
2. Uses that salt to generate a unique anonymous ID for your installation
3. This ID can't be traced back to you personally - it's just a random hash
4. Even if someone got the ID, they couldn't figure out who you are

THE SALT FILE:
- Stored in: /telemetry/salt.txt
- Contains random data used to make your anonymous ID
- Created once and reused (so your anonymous ID stays consistent)
- Includes explanation text about privacy protection

MIGRATION:
- If you had an old salt file, it automatically moves it to the new location
- This preserves your existing anonymous ID so statistics remain consistent
]]

local M = {}

-- Gets or creates the salt value used for anonymous ID generation
-- The salt is a long random string that makes each user's ID unique
local function getSalt()
  -- Make sure the telemetry directory exists
  if not FS:directoryExists("telemetry") then
    FS:directoryCreate("telemetry")
  end

  local oldSaltFile = '/gameTelemetries/.salt'
  local saltFile = '/telemetry/salt.txt'

  -- Handle migration: if old salt file exists, move it to new location
  -- This preserves the user's existing anonymous ID so statistics stay consistent
  if FS:fileExists(oldSaltFile) then
    local salt = readFile(oldSaltFile)
    FS:removeFile(oldSaltFile)  -- Clean up old file

    -- Write salt to new location exactly as-is (no banner to preserve user ID)
    local file = io.open(saltFile, 'w')
    file:write(salt)
    file:close()
    return salt
  end

  -- If salt file already exists in new location, just read and return it
  if FS:fileExists(saltFile) then
    return readFile(saltFile)
  end

  -- Create new salt file with explanatory banner for first-time users
  local file = io.open(saltFile, 'w')

  -- Add human-readable explanation at the top of the salt file
  local banner = [[This file contains a unique salt value used for anonymous telemetry data
collection. The salt is used to generate a hashed user identifier that cannot
be traced back to you personally. This helps us collect usage statistics while
protecting your privacy.

For more information about our data collection practices, please see:
https://go.beamng.com/privacyPolicy

Salt value:
]]
  file:write(banner)

  -- Generate salt as 6 lines of 80 random hex characters each
  for i = 1, 6 do
    file:write(SecureComm.getRandomBytesHexSlow(40))
    file:write('\n')
  end
  file:close()

  return readFile(saltFile)
end

-- Creates an anonymous user ID by hashing the salt
-- This creates a unique identifier that can't be traced back to the user
-- Think of it like turning your secret code into a badge number
local function getAnonymousUserID()
  return hashStringSHA256(getSalt())
end

-- Export the function so other parts of the game can get the anonymous ID
M.getAnonymousUserID = getAnonymousUserID

local function onExtensionLoaded()
  -- Prevent automatic unloading
  setExtensionUnloadMode(M, "manual")
end

M.onExtensionLoaded = onExtensionLoaded

return M