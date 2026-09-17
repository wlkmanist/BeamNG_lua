-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "ui_apps",
}

local layoutPath = "/settings/ui_apps/layouts/"
local originalLayoutPath = "/settings/ui_apps/originalLayouts/"
local typeLayoutMapPath = "/temp/ui-layout-map.json"

local currentLayout = nil
local usedLayout = nil
local editing = false
local typeLayoutMap = nil
local findOriginalLayoutByType

local function getAppIndexByName(layout, appName)
  if layout and layout.apps then
    for i, app in ipairs(layout.apps) do
      if app.appName == appName then
        return i
      end
    end
  end
  return nil
end

-- emit a layouts-only signal. consumers re-fetch via ui_apps.getUIAppsData
-- if they need the fresh list; we don't push a payload here.
local function notifyLayoutsChanged()
  if extensions.ui_apps and extensions.ui_apps.notifyLayoutsChanged then
    extensions.ui_apps.notifyLayoutsChanged()
  end
end

local function removedMarkerCoversVersion(removedVersion, appVersion)
  if removedVersion == true then return true end
  if type(removedVersion) ~= "number" then return false end
  if type(appVersion) ~= "number" then return true end
  return appVersion <= removedVersion
end

local function removeDeprecatedAppsFromLayout(layout, removedApps)
  if type(layout) ~= "table" or type(layout.apps) ~= "table" or type(removedApps) ~= "table" then return false end

  local changed = false
  for i = #layout.apps, 1, -1 do
    local app = layout.apps[i]
    if app and removedApps[app.appName] ~= nil then
      table.remove(layout.apps, i)
      changed = true
    end
  end
  return changed
end

local function readOriginalLayoutForUserLayout(filename, layout)
  if type(filename) == "string" and filename ~= "" then
    local originalFilePath = filename:gsub(layoutPath, originalLayoutPath)
    if FS:fileExists(originalFilePath) then
      return jsonReadFile(originalFilePath)
    end
  end

  local originalFilePath = findOriginalLayoutByType and findOriginalLayoutByType(layout and layout.type)
  if originalFilePath and FS:fileExists(originalFilePath) then
    return jsonReadFile(originalFilePath)
  end

  return nil
end

local function removeDeprecatedAppsFromOutputLayout(layout, origLayout)
  if origLayout and origLayout.removedApps then
    removeDeprecatedAppsFromLayout(layout, origLayout.removedApps)
  end
  return layout
end

local function isDeprecatedAppForLayout(layout, appName)
  if type(appName) ~= "string" or appName == "" then return false end
  local origLayout = readOriginalLayoutForUserLayout(layout and layout.filename, layout)
  return origLayout and origLayout.removedApps and origLayout.removedApps[appName] ~= nil
end

local function getAvailableLayouts()
  local res = {}
  for _, originalFilePath in ipairs(FS:findFiles(originalLayoutPath, '*.uilayout.json', -1, false, false)) do
    local userFilePath = originalFilePath:gsub(originalLayoutPath, layoutPath)
    local origLayout = jsonReadFile(originalFilePath)
    if FS:fileExists(userFilePath) then
      local userLayout = jsonReadFile(userFilePath)
      local userLayoutChanged = false

      -- legacy system of updating old user layouts which updates the whole layout at once
      -- copy over original if the user file version is older.
      if origLayout.version and (not userLayout.version or origLayout.version > userLayout.version) then
        userLayout = origLayout
        userLayoutChanged = true
      end

      -- go through the apps of the original layout one by one and update them in the user layout if they are newer
      if not userLayoutChanged then
        for _, originalApp in ipairs(origLayout.apps) do
          if originalApp.appVersion and not (origLayout.removedApps and origLayout.removedApps[originalApp.appName] ~= nil) then
            local userAppIndex = getAppIndexByName(userLayout, originalApp.appName)
            if userAppIndex then
              local userApp = userLayout.apps[userAppIndex]
              if userApp.appVersion == nil or userApp.appVersion < originalApp.appVersion then
                userLayout.apps[userAppIndex] = originalApp
                userLayoutChanged = true
              end
            elseif not (userLayout.removedApps and removedMarkerCoversVersion(userLayout.removedApps[originalApp.appName], originalApp.appVersion)) then
              -- add new app to user layout
              table.insert(userLayout.apps, originalApp)
              userLayoutChanged = true
            end
          end
        end
      end

      -- if the original layout has removed apps, keep the user file intact during load.
      -- because the original list is used as a deprecation list, filtering happens only in the UI-facing return pass below.

      if userLayoutChanged then
        jsonWriteFile(userFilePath, userLayout, true)
        log("I","",string.format("User layout was updated. File: %s", userFilePath))
      end
    else
      -- if no user file is found, add this layout to the return list
      origLayout.filename = userFilePath
      origLayout.resettable = true
      origLayout.userFileExists = false
      if originalFilePath:find('default') then
        origLayout.default = true
      end
      removeDeprecatedAppsFromOutputLayout(origLayout, origLayout)
      table.insert(res, origLayout)
    end
  end
  -- now go over all files in the user-ui folder and add them too
  local jsonFiles = FS:findFiles(layoutPath, '*.uilayout.json', -1, false, false)
  for _, fn in ipairs(jsonFiles) do
    local layout = jsonReadFile(fn)
    local origLayout = readOriginalLayoutForUserLayout(fn, layout)
    removeDeprecatedAppsFromOutputLayout(layout, origLayout)

    if fn:find('default') then
      layout.default = true
    end
    layout.filename = fn
    layout.resettable = FS:fileExists(fn:gsub(layoutPath, originalLayoutPath))
    layout.userFileExists = true
    table.insert(res, layout)
  end
  return res
end

local function findLayoutByFilename(filename)
  if type(filename) ~= "string" or filename == "" then return nil end
  for _, layout in ipairs(getAvailableLayouts()) do
    if layout.filename == filename then return layout end
  end
  return nil
end

local function loadTypeLayoutMap()
  if typeLayoutMap ~= nil then return typeLayoutMap end
  typeLayoutMap = {}
  if FS:fileExists(typeLayoutMapPath) then
    local data = jsonReadFile(typeLayoutMapPath)
    if type(data) == "table" then
      for layoutType, filename in pairs(data) do
        if type(layoutType) == "string" and layoutType ~= "" and type(filename) == "string" and filename ~= "" then
          typeLayoutMap[layoutType] = filename
        end
      end
    end
  end
  return typeLayoutMap
end

local function saveTypeLayoutMap()
  jsonWriteFile(typeLayoutMapPath, loadTypeLayoutMap(), true)
end

local function updateData(data)
  local version = data.version
  -- otherwise find original layout and return that version.
  if data.filename then
    -- find original layout for this file
    local originalFilePath = data.filename:gsub(layoutPath, originalLayoutPath)
    if FS:fileExists(originalFilePath) then
      local originalLayout = jsonReadFile(originalFilePath)
      for _, app in ipairs(originalLayout.apps) do
        local appIndex = getAppIndexByName(data, app.appName)
        if appIndex then
          -- if the app is in the user layout, update the app version with the original layout version
          data.apps[appIndex].appVersion = app.appVersion
        else
          -- if the app is not in the user layout, add it to the removed apps
          data.removedApps = data.removedApps or {}
          data.removedApps[app.appName] = app.appVersion
        end
      end

      -- if the app doesnt have a version, check if it is in the removed apps of the original layout and set the version to the removed app version
      for _, app in ipairs(data.apps) do
        if not app.appVersion then
          app.appVersion = originalLayout.removedApps and originalLayout.removedApps[app.appName]
        end
      end

      if not version and originalLayout then
        version = originalLayout.version
      end
    end
  end
  data['version'] = version
end

-- Internal write that persists the layout but skips the layouts-changed
-- notification. Used for high-frequency edits (drag commits, single-app
-- intents) so the editor doesn't thrash through reload cycles for every
-- change while the user is still interacting with the layout.
local function writeLayoutSilently(data)
  if not data['filename'] then
    dump({'invalid layout save data. Filename missing: ', data})
    return false
  end
  updateData(data)
  local filename = data['filename']
  removeDeprecatedAppsFromOutputLayout(data, readOriginalLayoutForUserLayout(filename, data))
  local resettable = data["resettable"]
  local userFileExists = data["userFileExists"]
  data['filename'] = nil
  data["resettable"] = nil
  data["userFileExists"] = nil
  jsonWriteFile(filename, data, true)
  data['filename'] = filename
  data["resettable"] = resettable
  data["userFileExists"] = userFileExists
  return true
end

local function saveLayout(data)
  if not writeLayoutSilently(data) then return end
  -- public save broadcasts UiAppLayoutsChanged so consumers refresh their views
  notifyLayoutsChanged()
end

local function deleteLayout(filenameToDelete)
  --dump({'deleteLayout', filenameToDelete})
  local layouts = getAvailableLayouts()
  for _, layout in ipairs(layouts) do
    --dump({'delete?', layout.filename, filenameToDelete})
    if layout.filename == filenameToDelete then
      if not isOfficialContentVPath(layout.filename) then
        log('I', '', 'deleting layout: ' .. tostring(layout.filename))
        FS:removeFile(layout.filename)
        notifyLayoutsChanged()
      else
        log('I', '', 'will not delete file as it is part of the official content distribution: ' .. tostring(layout.filename))
        notifyLayoutsChanged()
      end
      return true
    end
  end
  log('E', '', 'unable to delete layout - file not found: ' .. tostring(filenameToDelete))
  return false
end

function findOriginalLayoutByType(layoutType)
  if type(layoutType) ~= "string" or layoutType == "" then return nil end
  for _, originalFilePath in ipairs(FS:findFiles(originalLayoutPath, '*.uilayout.json', -1, false, false)) do
    local layout = jsonReadFile(originalFilePath)
    if layout and layout.type == layoutType then
      return originalFilePath
    end
  end
  return nil
end

local function resetLayout(filenameToReset, layoutType)
  local filename = type(filenameToReset) == "string" and filenameToReset ~= "" and filenameToReset or nil
  if filename and not string.startswith(filename, layoutPath) then
    log("W", "", "refusing to reset non-user layout: " .. tostring(filename))
    return false
  end

  local originalFilePath = filename and filename:gsub(layoutPath, originalLayoutPath) or nil
  if not originalFilePath or not FS:fileExists(originalFilePath) then
    local userLayout = filename and FS:fileExists(filename) and jsonReadFile(filename) or nil
    originalFilePath = findOriginalLayoutByType(layoutType or (userLayout and userLayout.type))
  end
  if not originalFilePath or not FS:fileExists(originalFilePath) then
    log("W", "", "no original layout found for: " .. tostring(filename or layoutType))
    return false
  end

  local resetFilename = originalFilePath:gsub(originalLayoutPath, layoutPath)
  local filenameToRemove = filename or resetFilename
  if FS:fileExists(filenameToRemove) then
    log("I", "", "deleting user layout: " .. tostring(filenameToRemove))
    FS:removeFile(filenameToRemove)
  end

  if currentLayout and currentLayout.filename == filenameToRemove then
    currentLayout = nil
  end
  notifyLayoutsChanged()
  return resetFilename
end

--- filename helpers ---

local function sanitiseFilenameStem(value)
  local s = tostring(value or "")
  s = s:lower()
  s = s:gsub("[^%w%-_]+", "_")
  s = s:gsub("_+", "_")
  s = s:gsub("^_+", ""):gsub("_+$", "")
  if s == "" then s = "layout" end
  return s
end

local function nextAvailableFilename(stem)
  local base = sanitiseFilenameStem(stem)
  local candidate = layoutPath .. base .. ".uilayout.json"
  if not FS:fileExists(candidate) then return candidate end
  for i = 2, 999 do
    candidate = layoutPath .. base .. "_" .. tostring(i) .. ".uilayout.json"
    if not FS:fileExists(candidate) then return candidate end
  end
  return nil
end

--- current layout selection ---

local function getCurrentLayout()
  removeDeprecatedAppsFromOutputLayout(currentLayout, readOriginalLayoutForUserLayout(currentLayout and currentLayout.filename, currentLayout))
  return currentLayout
end

local function setCurrentLayout(layoutOrFilename)
  if type(layoutOrFilename) == "string" then
    local found = findLayoutByFilename(layoutOrFilename)
    if not found then
      log("W", "", "appLayouts.setCurrentLayout: layout not found by filename: " .. tostring(layoutOrFilename))
      return nil
    end
    currentLayout = found
    notifyLayoutsChanged()
    return currentLayout
  end
  if type(layoutOrFilename) == "table" then
    removeDeprecatedAppsFromOutputLayout(layoutOrFilename, readOriginalLayoutForUserLayout(layoutOrFilename.filename, layoutOrFilename))
    currentLayout = layoutOrFilename
    notifyLayoutsChanged()
    return currentLayout
  end
  return nil
end

local function layoutStem(filename)
  if type(filename) ~= "string" then return nil end
  return filename:match("([^/]+)%.uilayout%.json$")
end

local function findDefaultLayoutByType(layoutType)
  local chosen = nil
  for _, layout in ipairs(getAvailableLayouts()) do
    if layout.type == layoutType then
      if layoutStem(layout.filename) == layoutType then return layout end
      if not chosen or (layout.default == true and chosen.default ~= true) then
        chosen = layout
      end
    end
  end
  return chosen
end

local function findLayoutByType(layoutType)
  if type(layoutType) ~= "string" or layoutType == "" then return nil end
  local map = loadTypeLayoutMap()
  local mappedFilename = map[layoutType]
  if mappedFilename then
    local mapped = findLayoutByFilename(mappedFilename)
    if mapped then return mapped end
    map[layoutType] = nil
    saveTypeLayoutMap()
  end
  return findDefaultLayoutByType(layoutType)
end

local function resolveLayout(idOrType)
  return findLayoutByFilename(idOrType) or findLayoutByType(idOrType)
end

local function setUsedLayout(idOrType)
  local layout = findLayoutByFilename(idOrType)
  local explicitChoice = layout ~= nil
  if not layout then
    layout = findLayoutByType(idOrType)
  end
  if not layout then
    log("W", "", "appLayouts.setUsedLayout: layout not found: " .. tostring(idOrType))
    return nil
  end
  if explicitChoice and type(layout.type) == "string" and layout.type ~= "" and layout.filename then
    local map = loadTypeLayoutMap()
    local defaultLayout = findDefaultLayoutByType(layout.type)
    if defaultLayout and defaultLayout.filename == layout.filename then
      -- picking the type's default is a restore-default gesture: drop any override
      if map[layout.type] ~= nil then
        map[layout.type] = nil
        saveTypeLayoutMap()
      end
    elseif map[layout.type] ~= layout.filename then
      map[layout.type] = layout.filename
      saveTypeLayoutMap()
    end
  end
  usedLayout = layout.filename or idOrType
  return setCurrentLayout(layout)
end

local function resetUsedLayout()
  if not usedLayout then return currentLayout end
  local layout = resolveLayout(usedLayout)
  if not layout then
    log("W", "", "appLayouts.resetUsedLayout: used layout not found: " .. tostring(usedLayout))
    return nil
  end
  return setCurrentLayout(layout)
end

--- layout-document CRUD ---

local function createLayout(data)
  data = data or {}
  local title = type(data.title) == "string" and data.title or "My Layout"
  local layoutType = type(data.type) == "string" and data.type or "custom"

  local filename = data.filename
  if type(filename) ~= "string" or filename == "" then
    filename = nextAvailableFilename(title)
  end
  if not filename then
    log("E", "", "appLayouts.createLayout: no available filename for title: " .. tostring(title))
    return nil
  end

  local payload = {
    apps = type(data.apps) == "table" and data.apps or {},
    title = title,
    type = layoutType,
    description = data.description,
    devonly = data.devonly == true or nil,
    version = data.version,
    filename = filename,
  }
  saveLayout(payload)
  return filename
end

local function renameLayout(filename, title)
  local layout = findLayoutByFilename(filename)
  if not layout then
    log("E", "", "appLayouts.renameLayout: layout not found: " .. tostring(filename))
    return false
  end
  if isOfficialContentVPath(filename) then
    log("W", "", "appLayouts.renameLayout: refusing to rewrite official layout: " .. tostring(filename))
    return false
  end
  layout.title = title
  saveLayout(layout)
  return true
end

local function duplicateLayout(filename, newTitle)
  local source = findLayoutByFilename(filename)
  if not source then
    log("E", "", "appLayouts.duplicateLayout: layout not found: " .. tostring(filename))
    return nil
  end
  local title = type(newTitle) == "string" and newTitle ~= "" and newTitle
    or ((source.title or source.type or "Layout") .. " copy")
  local newFilename = nextAvailableFilename(title)
  if not newFilename then
    log("E", "", "appLayouts.duplicateLayout: no available filename for title: " .. tostring(title))
    return nil
  end
  local clone = deepcopy(source)
  clone.filename = newFilename
  clone.title = title
  -- the duplicate is its own document; do not preserve the "default" flag  (which is derived from path on read anyway)
  clone.default = nil
  saveLayout(clone)
  return newFilename
end

--- app-list CRUD on a specific layout ---

local function resolveLayoutForWrite(layoutId)
  if type(layoutId) == "string" and layoutId ~= "" then
    return findLayoutByFilename(layoutId)
  end
  return nil
end

local function addApp(layoutId, appName, placement)
  if type(appName) ~= "string" or appName == "" then return false end
  local layout = resolveLayoutForWrite(layoutId)
  if not layout then
    log("E", "", "appLayouts.addApp: target layout not found: " .. tostring(layoutId))
    return false
  end
  if isDeprecatedAppForLayout(layout, appName) then
    log("W", "", "appLayouts.addApp: refusing to add deprecated app " .. tostring(appName) .. " to layout " .. tostring(layout.filename))
    return false
  end
  if type(layout.apps) ~= "table" then layout.apps = {} end

  local entry = { appName = appName }
  if type(placement) == "table" then entry.placement = placement end
  table.insert(layout.apps, entry)
  writeLayoutSilently(layout)
  return true
end

local function removeApp(layoutId, appInstanceIdOrIndex)
  local layout = resolveLayoutForWrite(layoutId)
  if not layout or type(layout.apps) ~= "table" then return false end

  local index
  if type(appInstanceIdOrIndex) == "number" then
    -- 0-based from JS, convert to 1-based Lua index.
    index = math.floor(appInstanceIdOrIndex) + 1
  elseif type(appInstanceIdOrIndex) == "string" then
    -- "appName-<idx>" form produced by the Vue store.
    local parsed = appInstanceIdOrIndex:match("^.*-(%d+)$")
    if parsed then index = tonumber(parsed) + 1 end
  end

  if not index or index < 1 or index > #layout.apps then
    log("W", "", "appLayouts.removeApp: invalid index " .. tostring(appInstanceIdOrIndex)
      .. " for layout " .. tostring(layout.filename))
    return false
  end

  table.remove(layout.apps, index)
  writeLayoutSilently(layout)
  return true
end

local function applyPlacementPatch(layoutId, appInstanceIdOrIndex, placement)
  if type(placement) ~= "table" then return false end
  local layout = resolveLayoutForWrite(layoutId)
  if not layout or type(layout.apps) ~= "table" then return false end

  local index
  if type(appInstanceIdOrIndex) == "number" then
    index = math.floor(appInstanceIdOrIndex) + 1
  elseif type(appInstanceIdOrIndex) == "string" then
    local parsed = appInstanceIdOrIndex:match("^.*-(%d+)$")
    if parsed then index = tonumber(parsed) + 1 end
  end

  if not index or index < 1 or index > #layout.apps then
    log("W", "", "appLayouts.applyPlacementPatch: invalid index "
      .. tostring(appInstanceIdOrIndex)
      .. " for layout " .. tostring(layout.filename))
    return false
  end

  local entry = layout.apps[index]
  if type(entry) ~= "table" then return false end
  entry.placement = placement
  writeLayoutSilently(layout)
  return true
end

local function applySettingsPatch(layoutId, appInstanceIdOrIndex, settings)
  if type(settings) ~= "table" then return false end
  local layout = resolveLayoutForWrite(layoutId)
  if not layout or type(layout.apps) ~= "table" then return false end

  local index
  if type(appInstanceIdOrIndex) == "number" then
    index = math.floor(appInstanceIdOrIndex) + 1
  elseif type(appInstanceIdOrIndex) == "string" then
    local parsed = appInstanceIdOrIndex:match("^.*-(%d+)$")
    if parsed then index = tonumber(parsed) + 1 end
  end

  if not index or index < 1 or index > #layout.apps then
    log("W", "", "appLayouts.applySettingsPatch: invalid index "
      .. tostring(appInstanceIdOrIndex)
      .. " for layout " .. tostring(layout.filename))
    return false
  end

  local entry = layout.apps[index]
  if type(entry) ~= "table" then return false end
  entry.settings = settings
  writeLayoutSilently(layout)
  return true
end

--- editor mode ---

local function setEditing(enabled)
  editing = enabled and true or false
  return editing
end

local function isEditing()
  return editing
end

local function setLayoutForType(layoutType, filename)
  if type(layoutType) ~= "string" or layoutType == "" then return false end
  if type(filename) ~= "string" or filename == "" then return false end
  if not findLayoutByFilename(filename) then
    log("W", "", "appLayouts.setLayoutForType: layout not found by filename: " .. tostring(filename))
    return false
  end
  local map = loadTypeLayoutMap()
  map[layoutType] = filename
  saveTypeLayoutMap()
  return true
end

local function clearLayoutForType(layoutType)
  if type(layoutType) ~= "string" or layoutType == "" then return false end
  local map = loadTypeLayoutMap()
  if map[layoutType] == nil then return false end
  map[layoutType] = nil
  saveTypeLayoutMap()
  return true
end

local function getLayoutForType(layoutType)
  if type(layoutType) ~= "string" or layoutType == "" then return nil end
  return loadTypeLayoutMap()[layoutType]
end

local function getTypeLayoutMap()
  return deepcopy(loadTypeLayoutMap())
end

M.getAvailableLayouts   = getAvailableLayouts
M.saveLayout            = saveLayout
M.deleteLayout          = deleteLayout
M.resetLayout           = resetLayout
M.getCurrentLayout      = getCurrentLayout
M.setCurrentLayout      = setCurrentLayout
M.setUsedLayout         = setUsedLayout
M.resetUsedLayout       = resetUsedLayout
M.createLayout          = createLayout
M.renameLayout          = renameLayout
M.duplicateLayout       = duplicateLayout
M.addApp                = addApp
M.removeApp             = removeApp
M.applyPlacementPatch   = applyPlacementPatch
M.applySettingsPatch    = applySettingsPatch
M.setEditing            = setEditing
M.isEditing             = isEditing
M.setLayoutForType      = setLayoutForType
M.clearLayoutForType    = clearLayoutForType
M.getLayoutForType      = getLayoutForType
M.getTypeLayoutMap      = getTypeLayoutMap

return M
