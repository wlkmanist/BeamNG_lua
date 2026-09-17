-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.impl = require("settings")

-- Headless/batch workers (many game instances at once) must not bind the companion
-- dev servers: their fixed ports (workbench LAN socket 8088, MCP 29292) collide across
-- instances and spam bind-retry logs. -nowebservers keeps both off for such runs.
local suppressWebServers = tableFindKey(Engine.getStartingArgs(), '-nowebservers') ~= nil

local options = {
  uiUnitLength = {modes={keys={'metric','imperial'}, values={'ui.unit.metric', 'ui.unit.imperial'}}},
  uiUnitTemperature = {modes={keys={'c', 'f', 'k'}, values={'ui.unit.c', 'ui.unit.f', 'ui.unit.k'}}},
  uiUnitWeight = {modes={keys={'lb', 'kg'}, values={'ui.unit.lb', 'ui.unit.kg'}}},
  uiUnitConsumptionRate = {modes={keys={'metric', 'imperial'}, values={'ui.unit.ltr100', 'ui.unit.mpg'}}},
  uiUnitTorque = {modes={keys={'metric', 'imperial'}, values={'ui.unit.nm', 'ui.unit.lbft'}}},
  uiUnitEnergy = {modes={keys={'metric', 'imperial'}, values={'ui.unit.j', 'ui.unit.ftlb'}}},
  uiUnitDate = {modes={keys={'ger', 'uk', 'us'}, values={'DD.MM.YYYY', 'DD/MM/YYYY', 'MM/DD/YYYY'}}},
  uiUnitPower = {modes={keys={'hp', 'bhp', 'kw'}, values={'ui.unit.hp', 'ui.unit.bhp', 'ui.unit.kw'}}},
  uiUnitVolume = {modes={keys={'l', 'gal'}, values={'ui.unit.l', 'ui.unit.gal'}}},
  uiUnitPressure = {modes={keys={'inHg', 'bar', 'psi', 'kPa'}, values={'ui.unit.inHg', 'ui.unit.bar', 'ui.unit.psi', 'ui.unit.kPa'}}},

  uiUpscaling = {modes={keys={0, 720, 1080, 1440}, values={'ui.common.disabled', '1280 x 720', '1920 x 1080', '2560 x 1440'}}},
  onlineFeatures = {modes={keys={'enable', 'disable'}, values={'ui.common.enable', 'ui.common.disable'}}},
  telemetry = {modes={keys={'enable', 'disable'}, values={'ui.common.enable', 'ui.common.disable'}}},
  defaultGearboxBehavior = {modes={keys={'arcade', 'realistic'}, values={'ui.common.arcade', 'ui.common.realistic'}}},
  absBehavior = {modes={keys={'realistic', 'off', 'arcade'}, values={'ui.common.ABSrealistic', 'ui.common.ABSoff', 'ui.common.ABSarcade'}}},
  escBehavior = {modes={keys={'arcade', 'realistic', 'off'}, values={'ui.common.arcade', 'ui.common.realistic', 'ui.common.off'}}},
  spawnVehicleIgnitionLevel = {modes={keys={0, 1, 2, 3}, values={'ui.common.vehicleOff', 'ui.common.vehicleAccessoryOn', 'ui.common.vehicleOn', 'ui.common.vehicleRunning'}}},
  communityTranslations = {modes={keys={'enable', 'disable'}, values={'ui.common.enable', 'ui.common.disable'}}},
  showMissionMarkers = {set = function(s) extensions.hook("showMissionMarkersToggled", s) end},
  enableDragRaceInFreeroam = {set = function(s) extensions.hook("showMissionMarkersToggled", s) end},
  enableDriftInFreeroam = {set = function(s) extensions.hook("showMissionMarkersToggled", s) end},
  enableDriftFreeroamCruising = {},
  enableCrawlInFreeroam = {set = function(s) extensions.hook("showMissionMarkersToggled", s) end},
  enableGasStationsInFreeroam = {set = function(s) extensions.hook("showMissionMarkersToggled", s) end},
  enableTaxiInFreeroam = {set = function(s) extensions.hook("taxiSettingChanged", s) end},
  enableVehicleTriggerCrosshairInternalCameras = {},
  enableVehicleTriggerCrosshairWalkingMode = {},
  enableMissionReplay = {modes = {keys={'count', 'maxSize'}, values = {'ui.common.replayCount', 'ui.common.size'}}},

  minimapMode = {modes={keys={'circle', 'rect'}, values={'ui.options.minimap.mode.circle', 'ui.options.minimap.mode.rect'}}, set = function(s) extensions.hook("onMinimapSettingsChanged", s) end},
  minimapOrientation = {modes={keys={'rotateWithCamera', 'alwaysPointNorth'}, values={'ui.options.minimap.orientation.rotateWithCamera', 'ui.options.minimap.orientation.alwaysPointNorth'}}, set = function(s) extensions.hook("onMinimapSettingsChanged", s) end},
  minimapDrawGrid = {modes={keys={'automatic', 'always', 'never'}, values={'ui.options.minimap.drawGrid.automatic', 'ui.options.minimap.drawGrid.always', 'ui.options.minimap.drawGrid.never'}}, set = function(s) extensions.hook("onMinimapSettingsChanged", s) end},
  minimapLookahead = {modes={keys={'disabled', 'low', 'medium', 'high'}, values={'ui.options.minimap.lookahead.disabled', 'ui.options.minimap.lookahead.low', 'ui.options.minimap.lookahead.medium', 'ui.options.minimap.lookahead.high'}}, set = function(s) extensions.hook("onMinimapSettingsChanged", s) end},
  poiListDisplayMode = {modes={keys={'hidden', 'tree', 'simple'}, values={'ui.options.bigmap.poiListDisplayMode.hidden', 'ui.options.bigmap.poiListDisplayMode.tree', 'ui.options.bigmap.poiListDisplayMode.simple'}}},
}


local values = deepcopy(M.impl.defaultValues)
local lastSavedTime = 0
local initFinalized = false

local function notifyUI()
  guihooks.trigger('SettingsChanged', {values = values, options = options})
end

local alreadySaving = false
local function save()
  if not initFinalized then return end -- too early to save, settings are not loaded yet
  if M.loadingSettingsInProgress then
    --log("W", "", "This call to save() settings is being ignored, because it is flagged as a recursive call via 'M.loadingSettingsInProgress'. This should not happen, please review callstack below:")
    --print(debug.tracesimple())
    return
  end

  if alreadySaving then
    --log("W", "", "This call to save() settings is being ignored, because it is flagged as a recursive call via 'alreadySaving'. This should not happen, please review callstack below:")
    --print(debug.tracesimple())
    return
  end
  lastSavedTime = os.clock()
  alreadySaving = true

  -- save options
  local localValues = {}
  local cloudValues = {}
  for k, v in pairs(values) do
    if values[k] == M.impl.defaultValues[k] then -- TODO do a deep table compare instead
      -- already the default, don't save it
    else
      if     (M.impl.defaults[k] or {})[1] == "local"    then
        localValues[k] = values[k]
      elseif (M.impl.defaults[k] or {})[1] == "cloud"   then
        cloudValues[k] = values[k]
      elseif (M.impl.defaults[k] or {})[1] == "discard" then
        -- don't save anywhere
      else
        localValues[k] = values[k]
      end
    end
  end
  FS:directoryCreate(M.impl.path)
  jsonWriteFile(M.impl.pathLocal, localValues, true)
  jsonWriteFile(M.impl.pathCloud, cloudValues, true)
  if not shipping_build and M.impl.internalValues then
    jsonWriteFile(M.impl.pathInternal, M.impl.internalValues, true)
  end

  VariableRegistry.exportToFile("$pref:*", settings.impl.pathVariables)

  -- let UI and Lua know
  notifyUI()
  core_settings_graphic.onSettingsChanged()
  extensions.hook('onSettingsChanged')
  be:queueAllObjectLua('onSettingsChanged()')
  alreadySaving = false
end

local function refreshTSState(withValue)
  if withValue then
    for k,o in pairs(options) do
      if type(o.get) == 'function' then
        values[k] = o.get()
      end
    end
  end
  for k,o in pairs(options) do
    if type(o.getModes) == 'function' then
      o.modes = o.getModes()
    end
  end
end

local appliedUserLanguage = nil
local appliedLanguage = ""
local function refreshLanguages()
  -- 0) ask c++ what language is active right now, so we can see if it changed later
  local oldLanguage = Lua:getSelectedLanguage()

  if not M.newTranslationsAvailable and (appliedLanguage ~= "" and oldLanguage ~= "" and appliedLanguage == oldLanguage) then
    if (values.userLanguage == appliedUserLanguage) then
      -- log('D','','       no language change requried.')
      return
    end
  else
    log('D','','refreshLanguages(): oldLanguage = '..dumps(oldLanguage)..'  appliedLanguage = '..dumps(appliedLanguage)..' userLanguage = '..dumps(values.userLanguage))
    log('D','','       switching language.')
  end

  local languageMap = require('utils/languageMap') -- load locally, so we don't have it hanging around in memory all the time

  -- 1) set new language
  Lua.userLanguage = values.userLanguage
  -- 2) ask C++ for the correct language
  Lua:reloadLanguages()
  -- 3) get the language that c++ chose
  values.userLanguageSelected = Lua:getSelectedLanguage()
  values.userLanguageSelectedLong = languageMap.resolve(values.userLanguageSelected)
  -- ui language is the same
  values.uiLanguage = values.userLanguageSelected
  --print(' * userLanguageSelected: ' .. tostring(values.userLanguageSelected) .. ' [' .. tostring(values.userLanguageSelectedLong) .. ']')

  -- info things for the UI, not used in the decision process
  -- list available languages
  options.userLanguagesAvailable = {}
  table.insert(options.userLanguagesAvailable, {key="", name="Automatic", isOfficial=true}) -- the empty ('') language will be auto - it'll use the OS/steam lang
  local availableLanguages = core_locales.getAvailableLanguages()

  for _, languageInfo in ipairs(availableLanguages) do
    table.insert(options.userLanguagesAvailable, {
      key = languageInfo.key,
      name = languageMap.resolve(languageInfo.key),
      isOfficial = isOfficialContentVPath(languageInfo.path)
    })
  end
  --print(' * languagesAvailable: ' .. dumps(options.userLanguagesAvailable))

  -- detailed info, only for the user
  values.languageOS = Lua:getOSLanguage()
  values.languageOSLong = languageMap.resolve(values.languageOS)
  --print(' * languageOS: ' .. tostring(values.languageOS) .. ' [' .. tostring(values.languageOSLong) .. ']')
  values.languageProvider = Lua:getSteamLanguage()
  values.languageProviderLong = OnlineServiceProvider and OnlineServiceProvider.language or ""
  --print(' * languageProvider: ' .. tostring(values.languageProvider) .. ' [' .. tostring(values.languageProviderLong) .. ']')

  -- was the language changed?
  local languageChanged = Lua:getSelectedLanguage() ~= oldLanguage
  if values.userLanguage ~= Lua:getSelectedLanguage() then
    -- the system chose another one, set back to automatic
    languageChanged = true
    values.userLanguage = ''
  end
  appliedLanguage = Lua:getSelectedLanguage()
  appliedUserLanguage = values.userLanguage
  --print(' - languageChanged >> ' .. tostring(languageChanged) .. ' | "' .. tostring(Lua:getSelectedLanguage()) .. '" ~= ' .. tostring(oldLanguage))

  -- send the new state to the UI
  if languageChanged or M.newTranslationsAvailable then
    M.newTranslationsAvailable = nil
    notifyUI()
    if ui_imgui and ui_imgui.ctx ~= nil then
      local imguiFonts = jsonReadFile('settings/imguiFonts.json') or {}
      local fontToApply = imguiFonts[appliedLanguage] or imguiFonts["default"]
      for index=0, ui_imgui.IoFontsGetCount() - 1 do
        if ffi.string(ui_imgui.IoFontsGetName(index)) == fontToApply then
          log("D", "", "set font: " .. ffi.string(ui_imgui.IoFontsGetName(index)))
          ui_imgui.SetDefaultFont(index)
          break
        end
      end
    end
  end
end

local function setState(newState, ignoreCache)
  if newState == nil then return end
  local isChanged = false
  local prevWorkbenchMobile = values.workbenchMobile
  local prevWorkbenchInsecure = values.workbenchInsecure

  -- Graphics quality groups that have preset values for groups of graphic settings
  local graphicQualityGroups = {'GraphicOverallQuality', 'GraphicMeshQuality', 'GraphicTextureQuality', 'GraphicLightingQuality', 'GraphicCloudsQuality', 'GraphicShadowsQuality', 'GraphicClusteredQuality'}

  local sortedKeys = {}
  for k,_ in pairs(newState) do
    if type(k) ~= "string" then
      log("W", "", "Ignoring setting with invalid non-string key: " .. dumps(k))
    elseif not tableContains(graphicQualityGroups, k) then
      table.insert(sortedKeys, k)
    end
  end

  table.sort(sortedKeys)

  -- Apply Graphics Quality states first because these control other settings that the user may have changed to create a custom setting
  for _,qualityKey in ipairs(graphicQualityGroups) do
    local value = newState[qualityKey]
    if value then
      isChanged = M.setValue(qualityKey, value, ignoreCache) or isChanged
    end
  end

  for _, k in ipairs(sortedKeys) do
    local s = newState[k]
    isChanged = M.setValue(k, s, ignoreCache) or isChanged
  end

  if not isChanged and not ignoreCache then return end

  -- get valid state from TS
  refreshTSState(true)

  if not M.loadingSettingsInProgress then
    save()
  else
    --log("W", "", "This call from setState to save() settings is not even attempted, because it is flagged via 'M.loadingSettingsInProgress' as a recursive call. This should not happen, please review callstack below:")
    --print(debug.tracesimple())
  end

  -- we can update the dynamic collision state on the fly
  if values.disableDynamicCollision ~= nil then
    be:setDynamicCollisionEnabled(not values.disableDynamicCollision)
  end

  local extLoaded = extensions.isExtensionLoaded('ui_extApp')
  if values.externalUI2 and not extLoaded then
    extensions.load('ui_extApp')
  elseif not values.externalUI2 and extLoaded then
    extensions.unload('ui_extApp')
  end

  local wantMcp = values.enableMcp and not suppressWebServers
  local mcpLoaded = extensions.isExtensionLoaded('mcp_server')
  if wantMcp and not mcpLoaded then
    if Engine.setMcpPort then Engine.setMcpPort(0) end -- 0 = loading until the server binds and publishes its real port
    extensions.load('mcp_server')
  elseif not wantMcp then
    if Engine.setMcpPort then Engine.setMcpPort(-1) end -- -1 = disabled, reported in "?info" so the supervisor shows "disabled"
    if mcpLoaded then extensions.unload('mcp_server') end
  end

  -- Workbench "Mobile (QR code)" + HTTPS: keep the LAN server in sync with its
  -- settings. activate() always binds 0.0.0.0 and rebinds when the workbenchInsecure
  -- TLS choice changed; it is idempotent otherwise, so reconciling on every apply is
  -- what makes a persisted "on" bind LAN at boot (startup applies saved settings here).
  -- An explicit mobile turn-off stops the server; otherwise a running server (mobile
  -- on, or started by the desktop app) just follows the insecure toggle.
  if not FS:fileExists("/lua/ge/extensions/workbench/webSocketHandler.lua") then
    -- skip workbench system entirely
  else
  if values.workbenchMobile and not suppressWebServers then
    extensions.load('workbench_webSocketHandler')
    workbench_webSocketHandler.activate()
  elseif extensions.isExtensionLoaded('workbench_webSocketHandler') then
    if values.workbenchMobile ~= prevWorkbenchMobile then
      workbench_webSocketHandler.deactivate()
    elseif values.workbenchInsecure ~= prevWorkbenchInsecure and workbench_webSocketHandler.getServer() then
      workbench_webSocketHandler.activate()
    end
  end
  end

  refreshLanguages()
end

local delayWriteTimer = 0
local function settingsTick(dtReal, dtSim, dtRaw)
  -- log('I','','settingsTick running... delayWriteTimer = '..tostring(delayWriteTimer)..'  dtReal = '..tostring(dtReal)..'  dtRaw = '..tostring(dtRaw))
  delayWriteTimer = delayWriteTimer - math.min(dtReal, 0.05) -- 20 fps = 0.05 sec
  if delayWriteTimer < 0 then
    save()
    delayWriteTimer = 0
    M.settingsTick = nop
  end
end

local function requestSave()
  delayWriteTimer = 0.5
  M.settingsTick = settingsTick
end

local settingInProgress = {}
local function setValue(key, value, ignoreCache)
  if settingInProgress[key] then
    --log("W", "", "This call to setValue() settings is being ignored, because it is flagged as a recursive call via 'M.settingInProgress["..dumps(key).."]'. This should not happen, please review callstack below:")
    --print(debug.tracesimple())
    return
  end

  settingInProgress[key] = true

  -- log('I','settings','setValue called  key = '..tostring(key)..'  value = '..tostring(value))
  -- apply to memory right now
  local stateDirty = false
  if ignoreCache or values[key] == nil or (tostring(value) ~= tostring(values[key])) then
    stateDirty = true
    values[key] = value
    if options[key] and type(options[key].set) == 'function' then
      options[key].set(value)
    end
  end
  settingInProgress[key] = false

  -- delay writing to disk
  if stateDirty and not M.loadingSettingsInProgress then
    M.requestSave()
  end
  return stateDirty
end

local function resetSettingToDefault(key)
  if M.impl.defaultValues[key] ~= nil then
    setValue(key, M.impl.defaultValues[key])
  end
end

local function getValue(key, defaultValue)
  if values[key] == nil then
    return defaultValue
  end
  return values[key]
end

local function loadSettingValues()
  M.impl.invalidateCache()
  local data = M.impl.getValues()

  if data.userColorPresets then
    data.userColorPresets = data.userColorPresets:gsub("'", '"') -- replace ' with "
    local ok, userColorPresets = pcall(json.decode, data.userColorPresets)
    if ok then
      local emptyMetallicData = {}
      local paints = {}
      for _, colorString in ipairs(userColorPresets)do
        local color = stringToTable(colorString)
        local paint = createVehiclePaint({x=color[1], y=color[2], z=color[3], w=color[4]}, emptyMetallicData)
        table.insert(paints, paint)
      end
      data.userPaintPresets = jsonEncode(paints)
      data.userColorPresets = nil
    else
      --pcall puts the error message in the 2nd return value
      log('W', '', "Couldn't decode json for userColorPresets: "..dumps(userColorPresets))
      log('W', '', "JSON data: "..dumps(data.userColorPresets))
    end
  end

  return data
end

local function load(ignoreCache)
  M.loadingSettingsInProgress = true
  -- ensure translation.zip is mounted before reloading the languages
  local translationsFilename = '/mods/translations.zip'
  if FS:fileExists(translationsFilename) and not FS:isMounted(translationsFilename) then
    FS:mount(translationsFilename)
  end

  refreshTSState(true)
  local newState = deepcopy(values)
  local data = loadSettingValues()
  tableMerge(newState, data)

  setState(newState, ignoreCache)
  core_settings_graphic.load(newState)

  if CppSettings.lastError ~= "" then
    -- any CppSettings error is logged before any console exists, so can be overlooked easily. We log it again here, for greater visibility
    log("E", "", "Last detected C++ settings error: "..CppSettings.lastError)
    log("E", "", "Please fix the issue, and then restart the program so the correct values are used by the C++ engine")
    guihooks.trigger("toastrMsg", {type="error", title="CppSettings error", msg=CppSettings.lastError})
  end
  M.loadingSettingsInProgress = false
end

local function initSettings(reason)
 -- fix the options up and combine the keys and values into the dict
  for k,v in pairs(options) do
    if v.keys and v.values and not v.dict then
      v.dict = {}
      for i = 0, tableSizeC(v.keys) - 1 do
        v.dict[v.keys[i]] = v.values[i]
      end
    end
  end

  -- build option helpers
  extensions.load({"core_settings_graphic","core_settings_audio", "core_settings_multiplayer"})
  tableMerge(options, core_settings_graphic.buildOptionHelpers())
  tableMerge(options, core_settings_audio.buildOptionHelpers())
  tableMerge(options, core_settings_multiplayer.buildOptionHelpers())
  -- add C++ propagation wherever possible
  for k,v in pairs(M.impl.defaults) do
    if CppSettings[k] ~= nil then -- check if C++ side cares about this setting
      options[k] = options[k] or {}
      if options[k].set == nil then
        -- no setter is defined, add one that propagates the value to C++ side
        options[k].set = function(value)
          if type(CppSettings[k]) == type(value) then
            CppSettings[k] = value
          else
            log("E", "", string.format("Unable to parse setting '%s': it should be a %s, but is a %s. The ignored value is: %s", k, type(CppSettings[k]), type(value), dumps(value)))
          end
        end
      else
        -- a setter was already defined, cannot add a setter to propagate value to C++ side
        log("E", "", string.format("Unable to propagate setting '%s' to C++ side, since it already has a custom setter in LUA side: this is likely a conflict of intentions that requires bugfixing", k))
      end
    end
  end

  -- load the persistency file at least
  local data = loadSettingValues()
  tableMerge(values, data)

  core_settings_graphic.onInitSettings(values)
end

local function loadPlatformSettings(platformSettingsPath)
  if platformSettingsPath and platformSettingsPath ~= "" then
    log('D', '', 'Loading platform-specific setings from: ' .. platformSettingsPath)
    local platformSettings = jsonReadFile(platformSettingsPath)
    if not platformSettings then
      log('E', '', 'Could not load custom settings JSON from: ' .. platformSettingsPath)
    else
      setState(platformSettings)
    end
  end
end

local function finalizeInit()
  -- force application of all settings the first time, since init() has not correctly applied all of them
  -- we could make init() call load(), but that would fail because it's still too early, and some stuff is not initialized yet
  load(true)
  core_settings_graphic.onFirstUpdateSettings()
  core_settings_audio.onFirstUpdateSettings()

  local techLicense = false
  if ResearchVerifier ~= nil then techLicense = ResearchVerifier.isTechLicenseVerified() end

  --Could be more optimal to call earlier?
  loadPlatformSettings(PlatformSwitches.settingsJsonPath)

  initFinalized = true
  -- the telemetry extension decides internally if it should be active or not
  extensions.load('telemetry_core')
end

local function onFilesChanged(files)
  if alreadySaving then
    return
  end

  local settingFileChanged = false
  for _,v in pairs(files) do
    if (v.filename == M.impl.pathLocal or v.filename == M.impl.pathCloud) and (os.clock()-lastSavedTime) > 5 then
      settingFileChanged = true
      break
    end
  end
  if settingFileChanged then
    load(false)
  end
end

local function getValuesCopy()
  return deepcopy(values)
end

local function exit()
  save()
end

local function stringToVersion(s)
  local a, b = s:match("^(%d+)%.(%d+)")
  return tonumber(a), tonumber(b)
end

local function onFirstUpdate()
  if getValue("communityTranslations") ~= "enable" then return end
  local updatedFromVersion = extensions.core_versionUpdate.updatedFromVersion()
  if not updatedFromVersion then return end
  local oldMajor, oldMinor = stringToVersion(updatedFromVersion)
  if oldMajor == 0 and oldMinor < 39 then
    updateTranslations()
  end
end

M.finalizeInit = finalizeInit
M.onFilesChanged = onFilesChanged
M.notifyUI = notifyUI
M.requestState = notifyUI -- retrocompatibility
M.refreshTSState = refreshTSState
M.requestSave = requestSave
M.setState = setState
M.setValue = setValue
M.getValue = getValue
M.getValuesCopy = getValuesCopy
M.save = requestSave
M.load = load
M.initSettings = initSettings
M.settingsTick = nop
M.loadPlatformSettings = loadPlatformSettings
M.exit = exit
M.resetSettingToDefault = resetSettingToDefault

M.onFirstUpdate = onFirstUpdate

return M
