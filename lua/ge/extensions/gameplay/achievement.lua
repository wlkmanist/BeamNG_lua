-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"gameplay_statistic"}

local ACHIEVEMENTS_JSON = "lua/ge/extensions/gameplay/achievements.json"

local pending = {}
local statWatchers = {}

local started = false
local timer = hptimer()

local function currentPlatformKey()
  if not OnlineServiceProvider.isWorking then
    return nil
  end
  return OnlineServiceProvider.providerToString(OnlineServiceProvider.primaryProviderType)
end

local function metricCareerInUse(metric)
  for _, p in ipairs(pending) do
    if p.metric == metric then
      return true
    end
  end
  for _, s in ipairs(statWatchers) do
    if s.metric == metric then
      return true
    end
  end
  return false
end

local function removeMetricHandlersIfUnused(metric)
  if not metricCareerInUse(metric) then
    gameplay_statistic.callbackRemove(metric, false, M.statCallback, false) --todo fix career flag (last)
  end
end

-- Stat rows: stat, statScale, scale, submitMinDelta; platformsOverride like achievements.
local function mergedStatConfig(raw, platformKey)
  local merged = {
    id = raw.id,
    scale = raw.scale,
    submitMinDelta = raw.submitMinDelta,
    disabled = raw.disabled or false,
  }
  local ov = raw.platformsOverride and raw.platformsOverride[platformKey]
  if type(ov) == "table" then
    for k, v in pairs(ov) do
      merged[k] = v
    end
  end
  return merged
end

local function maybeSubmitStat(watcher, metricVal)
  local val = metricVal
  local v = val * (watcher.scale or 1)
  watcher.valueQueued = v
  if timer:stop() - watcher.valueLastSent > 20 or math.abs(v - watcher.valueLastSent) >= watcher.submitMinDelta then
    log("D", "gameplay_achievement", "maybeSubmitStat: "..dumps(watcher.id, v))
    OnlineServiceProvider.setStatInt(watcher.id, v)
    watcher.valueLastSent = timer:stop()
  end
end

local function maybeSubmitProgressStat(a, metricVal)
  if not a.progressStatEnabled or not a.progressStat then
    return
  end
  local statVal = (metricVal) * (a.progressScale or 1)
  local minD = a.progressSubmitMinDelta
  if type(minD) ~= "number" or minD <= 0 then
    log("D", "gameplay_achievement", "maybeSubmitProgressStat1: "..dumps(a.progressStat, statVal))
    OnlineServiceProvider.setStat(a.progressStat, statVal)
    return
  end
  a.progressQueued = statVal
  if a.progressLastSent == nil or math.abs(a.progressQueued - a.progressLastSent) >= minD then
    log("D", "gameplay_achievement", "maybeSubmitProgressStat2: "..dumps(a.progressStat, statVal))
    OnlineServiceProvider.setStat(a.progressStat, statVal)
    a.progressLastSent = statVal
  end
end

local function flushPendingOnlineStats()
  if not OnlineServiceProvider.isWorking then
    return
  end
  for _, w in ipairs(statWatchers) do
    if w.queuedInt ~= nil and (w.lastSubmittedInt == nil or w.lastSubmittedInt ~= w.queuedInt) then
      OnlineServiceProvider.setStatInt(w.id, w.queuedInt)
      w.lastSubmittedInt = w.queuedInt
    end
  end
  for _, a in ipairs(pending) do
    if a.progressStatEnabled and a.progressStat and type(a.progressSubmitMinDelta) == "number" and a.progressSubmitMinDelta > 0 and a.progressQueued ~= nil then
      OnlineServiceProvider.setStat(a.progressStat, a.progressQueued)
      a.progressLastSent = a.progressQueued
    end
  end
end

local function statCallback(key, oldvalue, newvalue)
  local career = newvalue.career == true
  local val = (newvalue and newvalue.value) or 0
  -- log("D", "statCallback", "key: "..dumps(key).."|oldvalue: "..dumps(oldvalue).."|newvalue: "..dumps(newvalue))

  for _, w in ipairs(statWatchers) do
    if w.metric == key and w.career == career then
      maybeSubmitStat(w, val)
    end
  end

  local i = 1
  while i <= #pending do
    local a = pending[i]
    if a.metric == key and a.career == career then
      maybeSubmitProgressStat(a, val)
      if val >= a.unlockAt then
        OnlineServiceProvider.unlockAchievement(a.id)
        table.remove(pending, i)
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  removeMetricHandlersIfUnused(key)
end

-- Baseline: achievement, progressStatEnabled, progressStat, progressScale, scale, progressSubmitMinDelta.
-- platformsOverride[steam|eos]: only keys that differ from baseline for that store.
-- progressStatEnabled: must be true to push progress via maybeSubmitProgressStat; progressStat is the provider stat name.
-- progressSubmitMinDelta: if omitted or <= 0, setStat is called every update (legacy). If > 0, submit only when the float changes by at least that much; value is queued between submits.
local function mergedPlatformConfig(raw, platformKey)
  local merged = deepcopy(raw)
  local ov = raw.platformsOverride and raw.platformsOverride[platformKey]
  if ov and type(ov) == "table" then
    tableMergeRecursive(merged, ov)
  end
  return merged
end

local function buildPendingEntry(raw, platformKey)
  if type(raw) ~= "table" then
    return nil
  end
  if type(raw.id) ~= "string" or type(raw.metric) ~= "string" or type(raw.unlockAt) ~= "number" then
    log("W", "buildPendingEntry", "skip achievement: missing id, metric, or unlockAt")
    return nil
  end
  local pl = mergedPlatformConfig(raw, platformKey)
  local scale = pl.progressScale
  if scale == nil then
    scale = pl.scale
  end
  if type(scale) ~= "number" then
    scale = 1
  end
  local progressSubmitMinDelta = pl.progressSubmitMinDelta
  if progressSubmitMinDelta ~= nil and type(progressSubmitMinDelta) ~= "number" then
    progressSubmitMinDelta = nil
  end
  local progressStatEnabled = pl.progressStatEnabled == true
  local progressStat = type(pl.progressStat) == "string" and pl.progressStat or nil
  if progressStatEnabled and not progressStat then
    log("W", "buildPendingEntry", "achievement " .. raw.id .. ": progressStatEnabled but missing progressStat, progress sync off")
    progressStatEnabled = false
  end
  pl["progressStatEnabled"] = progressStatEnabled
  pl["progressStat"] = progressStat
  pl["progressScale"] = scale
  pl["progressSubmitMinDelta"] = progressSubmitMinDelta
  pl["platformsOverride"] = nil
  return pl
end

local function buildStatEntry(raw, platformKey)
  if type(raw) ~= "table" then
    log("E", "buildStatEntry", "missing table")
    return nil
  end
  if type(raw.id) ~= "string" or type(raw.metric) ~= "string" then
    log("E", "buildStatEntry", "skip stat: missing id or metric")
    return nil
  end
  local pl = mergedStatConfig(raw, platformKey)
  return {
    id = pl.id,
    metric = raw.metric,
    career = raw.career == true,
    scale = pl.scale or 1,
    submitMinDelta = pl.submitMinDelta or 1,
    valueQueued = 0,
    valueLastSent = 0,
    disabled = pl.disabled,
  }
end

local function _cbVehicleExplorer(metric, oldentry, newentry)
  local r = gameplay_statistic.metricGetMatchPattern("vehicle/odometer/.*", false)
  local i = 0
  for name, entry in pairs(r) do
    if entry.value >= 10000 then
      i = i + 1
      -- log("I", "_cbVehicleExplorer", "name="..dumps(name).."|entry.value="..dumps(entry.value))
    end
  end
  -- log("I", "_cbVehicleExplorer", "i="..dumps(i))
  if i >= 15 then
    OnlineServiceProvider.unlockAchievement("VEHICLE_EXPLORER")
    gameplay_statistic.callbackRemove("vehicle/odometer/.*", nil, _cbVehicleExplorer)
    return true
  end
  return false
end

local function _cbLevelExplorer(metric, oldentry, newentry)
  local r = gameplay_statistic.metricGetMatchPattern("general/map/.*%.time", false)
  local i = 0
  for name, entry in pairs(r) do
    if entry.value >= 300 then
      i = i + 1
    end
  end
  if i >= 5 then
    OnlineServiceProvider.unlockAchievement("LEVEL_EXPLORER")
    gameplay_statistic.callbackRemove("general/map/.*%.time", nil, _cbLevelExplorer)
    return true
  end
  return false
end

local function _cbVehicleFavourite(metric, oldentry, newentry)
  if newentry then
    if newentry.value >= 1000000 then
      OnlineServiceProvider.unlockAchievement("VEHICLE_FAVOURITE")
      return true
    else
      return false
    end
  end
  local r = gameplay_statistic.metricGetMatchPattern("vehicle/odometer/.*", false)
  for name, entry in pairs(r) do
    local a = _cbVehicleFavourite(name, nil, entry)
    if a then return true end
  end
  log("E", "_cbVehicleFavourite", "no metric found")
  -- gameplay_statistic.callbackRemove("vehicle/odometer/.*", 1000000, _cbVehicleFavourite)
  return false
end

local function checkManualAchievements()
  if not OnlineServiceProvider.isAchievementUnlocked("VEHICLE_EXPLORER") then
    if not _cbVehicleExplorer(nil, nil, nil) then
      gameplay_statistic.callbackRegister("vehicle/odometer/.*", nil, _cbVehicleExplorer)
    end
  end

  if not OnlineServiceProvider.isAchievementUnlocked("LEVEL_EXPLORER") then
    if not _cbLevelExplorer(nil, nil, nil) then
      gameplay_statistic.callbackRegister("general/map/.*%.time", nil, _cbLevelExplorer)
    end
  end

  if not OnlineServiceProvider.isAchievementUnlocked("VEHICLE_FAVOURITE") then
    if not _cbVehicleFavourite(nil, nil, nil) then
      gameplay_statistic.callbackRegister("vehicle/odometer/.*", 1000000, _cbVehicleFavourite)
    end
  end
end

local function startup()
  -- log("D", "startup", "!!!!!!!!!!!!!!!")
  if started then
    return false
  end

  local platformKey = currentPlatformKey()
  if not platformKey then
    log("W", "startup", "no online platform mapped; achievements inactive")
    return false
  end

  local data = jsonReadFile(ACHIEVEMENTS_JSON)
  if not data or type(data) ~= "table" then
    log("E", "startup", "missing or invalid " .. ACHIEVEMENTS_JSON)
    return false
  end

  local achievementsList = type(data.achievements) == "table" and data.achievements or {}
  local statsList = type(data.stats) == "table" and data.stats or {}
  if #achievementsList == 0 and #statsList == 0 then
    log("E", "startup", ACHIEVEMENTS_JSON .. " has no achievements or stats")
    return false
  end

  pending = {}
  statWatchers = {}
  local manualAchievementsRemaining = checkManualAchievements()

  for _, raw in ipairs(achievementsList) do
    local entry = buildPendingEntry(raw, platformKey)
    if entry and not entry.disabled and not OnlineServiceProvider.isAchievementUnlocked(entry.id) then
      pending[#pending + 1] = entry
    end
  end

  local manualAchievements = {"VEHICLE_FAVOURITE","LEVEL_EXPLORER","VEHICLE_EXPLORER"}
  local manualAchievementsRemaining = 0
  for n in ipairs(manualAchievements) do
    if not OnlineServiceProvider.isAchievementUnlocked(n) then
      manualAchievementsRemaining = manualAchievementsRemaining + 1
    end
  end


  local i = 1
  while i <= #pending do
    local e = pending[i]
    local m = gameplay_statistic.metricGet(e.metric, e.career)
    local val = m and m.value or 0
    if val >= e.unlockAt then
      OnlineServiceProvider.unlockAchievement(e.id)
      table.remove(pending, i)
    else
      i = i + 1
    end
  end

  for _, raw in ipairs(statsList) do
    local entry = buildStatEntry(raw, platformKey)
    if entry and not entry.disabled then
      statWatchers[#statWatchers + 1] = entry
    end
  end

  if #pending == 0 and #statWatchers == 0 then
    return false
  end

  started = true

  local registered = {}
  local function reg(metric, career)
    local regKey = metric .. "\0" .. tostring(career)
    if not registered[regKey] then
      registered[regKey] = true
      gameplay_statistic.callbackRegister(metric, false, M.statCallback, career)
    end
  end

  for _, e in ipairs(pending) do
    reg(e.metric, e.career)
  end
  for _, s in ipairs(statWatchers) do
    reg(s.metric, s.career)
  end

  for _, s in ipairs(statWatchers) do
    local m = gameplay_statistic.metricGet(s.metric, s.career)
    local val = m and m.value or 0
    maybeSubmitStat(s, val)
  end
end

local function onFirstUpdate()
  if OnlineServiceProvider.isWorking then
    startup()
  else
    log("W", "onFirstUpdate", "online service provider not working; achievements inactive")
  end
end

local function onOnlineServiceProviderReady()
  startup()
end

local function onClientStartMission()
  startup()
end

local function onExtensionUnloaded()
  flushPendingOnlineStats()
end

local unlockedAchievementsThisSession = {}
local function unlockAchievement(achievementId)
  if unlockedAchievementsThisSession[achievementId] then
    return
  end
  unlockedAchievementsThisSession[achievementId] = true
  log("I", "unlockAchievement", achievementId)
  OnlineServiceProvider.unlockAchievement(achievementId)
end

M.onFirstUpdate = onFirstUpdate
M.onOnlineServiceProviderReady = onOnlineServiceProviderReady
M.onExtensionUnloaded = onExtensionUnloaded
M.onClientStartMission = onClientStartMission

M.unlockAchievement = unlockAchievement
M.statCallback = statCallback

return M
