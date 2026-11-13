-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY SESSION TRACKER

  Tracks session start and end.
  This tracker loads first and unloads last, so it frames every other event.

  A game engine Lua reload continues the current session and adds a luaReload event.

  All times here are the local clock, which can be wrong by hours. The login measures
  the offset against the server clock, but it only arrives long after the session
  started, so it is reported separately as the login event.

  That event also carries the server timestamp as the string the server sent, so the
  report holds a time that does not depend on the player's clock at all.
]]

local M = {}
M.dependencies = {'telemetry_core'}

local clientFacts = require("ge/extensions/telemetry/clientFacts")

local loginLogged = false
local reloading = false

-- core can unload this tracker while the whole extension list is already being torn down,
-- which would run the unload twice and report two ends for one session
local sessionEnded = false

-- Records the server clock once authentication is available. A config change can restart
-- telemetry after login, so onOnlineStateChanged is not guaranteed to fire for this session.
local function logLogin()
  if loginLogged or not Engine.Online.isAuthenticated() then return end
  loginLogged = true

  extensions.telemetry_core.addEvent({
    name = "login",
    clockOffset = SecureComm.getServerTimeOffsetSeconds(),
    utcTime = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    utcTimeAdjusted = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + SecureComm.getServerTimeOffsetSeconds()),
    serverTime = SecureComm.getServerTime(),
  })
end

-- Minutes the local clock runs ahead of UTC, DST included. The zone name is left out, a
-- localized Windows returns it in the local codepage, which is not valid UTF-8.
local function getTimezoneOffsetMinutes()
  local now = os.time()
  local utc = os.date("!*t", now)
  -- without the DST flag of the local clock, os.time answers with the standard offset all year
  utc.isdst = os.date("*t", now).isdst
  return math.floor(os.difftime(now, os.time(utc)) / 60 + 0.5)
end

-- Lifecycle functions
local function onExtensionLoaded(previousState)
  local continued = extensions.telemetry_core.isSessionContinued()
  if continued then
    loginLogged = type(previousState) == "table" and previousState.loginLogged == true
  else
    local event = clientFacts.collect()
    event.name = "session"
    event.type = "start"
    event.sessionId = extensions.telemetry_core.getSessionId()
    event.startReason = luaVmStartReason or "unknown"
    event.telemetryVersion = extensions.telemetry_configManager.getTelemetryVersion()
    event.reportIntervalHours = extensions.telemetry_configManager.getConfig().reportIntervalHours
    -- the runs this session collects for. telemetry_core starts a new session whenever
    -- the set changes, so it holds for every event in this session. Which project each
    -- run serves and which trackers it asked for is the server's own record.
    event.telemetryRunIds = extensions.telemetry_core.getRunIds()
    event.osLanguage = Lua:getOSLanguage()
    event.providerLanguage = OnlineServiceProvider.language
    event.gameLanguage = Lua:getSelectedLanguage()
    event.userLanguage = Lua.userLanguage
    event.techLicense = ResearchVerifier ~= nil and ResearchVerifier.isTechLicenseVerified() or false
    event.startTime = os.date("!%Y-%m-%dT%H:%M:%SZ")
    event.timezoneOffsetMinutes = getTimezoneOffsetMinutes()
    event.anonymousUserID = extensions.telemetry_userIdentity.getAnonymousUserID()
    event.bigPicture = os.getenv("SteamTenfoot") ~= nil
    event.power = Engine.Platform.getPowerInfo()
    event.vr = render_openxr and render_openxr.isSessionRunning() or false
    extensions.telemetry_core.addEvent(event)
  end

  logLogin()

  -- Prevent automatic unloading
  setExtensionUnloadMode(M, "manual")
end

local function onExtensionUnloaded()
  if reloading then return end
  if sessionEnded then return end
  sessionEnded = true

  extensions.telemetry_core.addEvent({
    name = "session",
    type = "end",
    duration = extensions.telemetry_core.getRunTime(),
    endTime = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  })
end

local function onSerialize(reason)
  reloading = reason == "reload"
  return {loginLogged = loginLogged}
end

-- Fired once the login came back, which is the first moment the server clock is known.
-- utcTimeAdjusted together with the event's own t anchors every other event in this session.
local function onOnlineStateChanged(connected)
  if connected then logLogin() end
end

M.onOnlineStateChanged = onOnlineStateChanged
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onSerialize = onSerialize

return M