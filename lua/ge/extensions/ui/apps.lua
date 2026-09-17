-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local appsDir = "/ui/modules/apps/"
-- Layout files (shipped + user) live here. Watching the prefix is enough.
local layoutsRoot = "/settings/ui_apps/"

local simplemenu = Engine.UI.isSimpleMenu()

local ALLOWED_APP_POSITION_KEYS = tableValuesAsLookupDict({
  "left",
  "right",
  "top",
  "bottom",
  "width",
  "height",
  "margin", -- subject to be deprecated
})

local function filterAllowedAppPositionKeys(position)
  if type(position) ~= "table" then return end
  for key, _ in pairs(position) do
    if not ALLOWED_APP_POSITION_KEYS[key] then
      position[key] = nil
    end
  end
end

local function appSimplemenuMatches(appData)
  -- if simplemenu and appData.isAuxiliary then return false end
  return appData.simplemenu == nil or appData.simplemenu == simplemenu
end

local function discoverVueAppFiles()
  local byFolderColocated = {}
  local byDirective       = {}
  local byDirectiveIsDev  = {}

  local function basenameOf(filepath)
    return filepath:match("([^/]+)$")
  end

  local function parentFolderOf(filepath)
    -- last path segment before the basename
    return filepath:match("([^/]+)/[^/]+$")
  end

  local function directiveFromVariantName(name)
    if not name then return nil, false end
    local variant = name:match("^app%.(.+)%.vue$")
    if not variant then return nil, false end
    local isDev = variant:find("%.dev$") ~= nil
    if isDev then
      variant = variant:gsub("%.dev$", "")
    end
    if variant == "" then return nil, false end
    return variant, isDev
  end

  for _, fp in ipairs(FS:findFiles(appsDir, "app*.vue", -1, false, false)) do
    local name = basenameOf(fp)
    local folder = parentFolderOf(fp)
    if name and folder then
      if name == "app.vue" then
        byFolderColocated[folder] = fp
      else
        local directive, isDev = directiveFromVariantName(name)
        if directive and (not byDirective[directive] or (byDirectiveIsDev[directive] and not isDev)) then
          byDirective[directive] = fp
          byDirectiveIsDev[directive] = isDev
        end
      end
    end
  end

  return byFolderColocated, byDirective
end

local function buildSourceOnlyEntry(appName, vueFile)
  local types = { 'ui.apps.categories.internal' }
  local typesTranslated = {}
  for _, typeKey in ipairs(types) do
    table.insert(typesTranslated, _tr(typeKey, typeKey))
  end
  return {
    appName               = appName,
    directive             = appName,
    domElement            = nil,
    name                  = appName,
    description           = "",
    css                   = {},
    types                 = types,
    typesLookup           = tableValuesAsLookupDict(types),
    typesTranslated       = typesTranslated,
    typesTranslatedLookup = tableValuesAsLookupDict(typesTranslated),
    author                = "BeamNG.UI Team",
    version               = "0.1",
    category              = "Embedded",
    folder                = vueFile:match("([^/]+)/[^/]+$"),
    appJsonPath           = nil,
    jsSource              = nil,
    hasAppJs              = false,
    vueFile               = vueFile,
    hasAppVue             = true,
    isAuxiliary           = true,
    interactive           = "no",
    essential             = false,
    devonly               = false,
    photomode             = false,
    official              = isOfficialContentVPath(vueFile),
    sourceOnly            = true,  -- flag to indicate that the app is a source-only app and should be hidden from app browser
    previews              = {},
  }
end

local function getAvailableAppList()
  local jsonFiles = FS:findFiles(appsDir, "app.json", -1, false, false)
  local res = {}
  local byFolderColocated, byDirective = discoverVueAppFiles()
  local consumedVueFiles = {}
  for _, fn in ipairs(jsonFiles) do
    local appDir = path.split(fn)
    if appDir then
      local appData = jsonReadFile(fn)
      filterAllowedAppPositionKeys(appData.css)
      appData.official = isOfficialContentVPath(fn)
      appData.previews = {
        imageExistsDefault(appDir..'app.png'),
        fileExistsOrNil(appDir..'app2.png'),
        fileExistsOrNil(appDir..'app3.png'),
      }

      appData["official"] = isOfficialContentVPath(appDir)

      if not appData.types then
        appData.types = {'ui.apps.categories.unknown'}
      end

      appData.typesLookup = tableValuesAsLookupDict(appData.types)

      -- Add translated types for display
      appData.typesTranslated = {}
      for _, typeKey in ipairs(appData.types) do
        table.insert(appData.typesTranslated, _tr(typeKey, typeKey))
      end
      appData.typesTranslatedLookup = tableValuesAsLookupDict(appData.typesTranslated)

      appData["appName"] = appData["appName"] or appData["directive"]

      if appData["domElement"] and appData["directive"] and appData["appName"] then
        appData["jsSource"] = appDir..'app.js'
        appData["hasAppJs"] = FS:fileExists(appData["jsSource"])
        local folderName = fn:match("([^/]+)/[^/]+$")
        appData["folder"] = folderName
        appData["appJsonPath"] = fn
        local vueFile = folderName and byFolderColocated[folderName] or nil
        if not vueFile and appData["directive"] then
          vueFile = byDirective[appData["directive"]]
        end
        if not vueFile and appData["appName"] then
          vueFile = byDirective[appData["appName"]]
        end
        appData["vueFile"]   = vueFile
        appData["hasAppVue"] = vueFile ~= nil
        if vueFile then consumedVueFiles[vueFile] = true end
        appData["essential"] = appData["essential"] == true
        appData["isAuxiliary"] = appData["isAuxiliary"] == true
        appData["photomode"] = appData["photomode"] == true  -- photomode apps are hidden from the normal ui app selector
        appData["interactive"] = appData["interactive"] == nil or appData["interactive"] == "required" or appData["interactive"] == "yes" or appData["interactive"] == true
        if appSimplemenuMatches(appData) then
          res[appData.appName] = appData
        end
      else
        log('E', 'apps', 'invalid app data:' .. tostring(fn) .. ': missing "domElement" or "directive" in app.json - IGNORING APP: ' .. dumps(appData))
      end
      --dump(appData)
    else
      log('E', 'apps', 'unable to read app from dir:' .. tostring(fn))
    end
  end

  local function addSourceOnly(appName, vueFile)
    if not appName or not vueFile then return end
    if consumedVueFiles[vueFile] then return end
    if res[appName] then return end
    res[appName] = buildSourceOnlyEntry(appName, vueFile)
    consumedVueFiles[vueFile] = true
  end
  -- colocated `/ui/modules/apps/<Folder>/app.vue` without app.json
  for _, fp in pairs(byFolderColocated) do
    addSourceOnly(fp:match("([^/]+)/[^/]+$"), fp)
  end
  -- variant files like `<folder>/app.<variant>.vue` without app.json
  for variant, fp in pairs(byDirective) do
    addSourceOnly(variant, fp)
  end

  return res
end

local function getAvailableLayouts()
  if extensions.ui_appLayouts and extensions.ui_appLayouts.getAvailableLayouts then
    return extensions.ui_appLayouts.getAvailableLayouts()
  end
  return {}
end

local function getUIAppsData()
  local t0 = os.clockhp()
  local result = getAvailableAppList()
  local dt = os.clockhp() - t0
  if dt > 0.1 then log("W","",string.format("getUIAppsData() took too long: %.0f ms. This probably needs optimization.", dt * 1000)) end
  return result
end

local function notifyLayoutsChanged()
  guihooks.trigger('UiAppLayoutsChanged')
end

local nextLayoutsRefresh = nil

local function onFilesChanged(files)
  for _,v in ipairs(files) do
    -- layout file changes are owned here
    -- app catalogue source changes are handled by ui_uiMods via UiAppsChanged
    if string.startswith(v.filename, layoutsRoot) then
      nextLayoutsRefresh = os.clockhp() + 0.2
    end
  end
end

local function onUpdate()
  local now = os.clockhp()
  if nextLayoutsRefresh and now >= nextLayoutsRefresh then
    nextLayoutsRefresh = nil
    notifyLayoutsChanged()
  end
end

M.onFilesChanged = onFilesChanged
M.notifyLayoutsChanged = notifyLayoutsChanged
M.getUIAppsData = getUIAppsData
M.onUpdate = onUpdate

return M
