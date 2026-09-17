-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.onExtensionLoaded = function()
  setExtensionUnloadMode(M, "manual")
end

local IMAGE_EXTENSIONS = {
  jpg = true,
  jpeg = true,
  jfif = true,
  png = true,
  gif = true,
  webp = true,
  avif = true,
}
local watchedImagePaths = {}

local runtimeFileRevs = {}
local runtimeFileMtimes = {}

local runtimeBundleIncludes = {
  "/ui/ui-vue/src/",
  "/ui/ui-vue/generated/",
}
local runtimeBundleExcludes = {
  "/ui/ui-vue/src/modules/",
}
local runtimeStatExts = {
  js = true, mjs = true, cjs = true, vue = true, scss = true, css = true,
}
local runtimeStyleExts = {
  scss = true, css = true,
}

local function getVueMods()
  local modDir = "/ui/ui-vue/mods"
  local files = FS:findFiles(modDir, "*.*", -1, true, false)
  local mods = {}

  for _, filepath in ipairs(files) do
    local segments = split(filepath, "/")
    --   1    2       3        4        5            6
    -- ["", "ui", "ui-vue", "mods", "modname", "something.vue"]
    if #segments >= 6 then
      local modname = segments[5]
      if not mods[modname] then
        mods[modname] = { path = modDir .. "/" .. modname, files = {} }
      end
      local relPath = filepath:sub(#modDir + #modname + 2)
      table.insert(mods[modname].files, relPath)
    end
  end

  return mods
end

local function getUiApps()
  if not (extensions.ui_apps and extensions.ui_apps.getUIAppsData) then
    return {}
  end
  local available = extensions.ui_apps.getUIAppsData() or {}
  local res = {}
  for appName, app in pairs(available) do
    res[appName] = {
      appName      = app.appName,
      directive    = app.directive,
      domElement   = app.domElement,
      jsSource     = app.jsSource,
      folder       = app.folder,
      appJsonPath  = app.appJsonPath,
      css          = app.css,
      name         = app.name,
      types        = app.types,
      description  = app.description,
      author       = app.author,
      version      = app.version,
      category     = app.category,
      isAuxiliary  = app.isAuxiliary,
      interactive  = app.interactive,
      photomode    = app.photomode == true,
      vueParams    = app.vueParams,
      vueFile      = app.vueFile,
      hasAppVue    = app.hasAppVue == true,
      hasAppJs     = app.hasAppJs == true,
      essential    = app.essential == true,
      devonly      = app.devonly == true,
      official     = app.official == true,
      sourceOnly   = app.sourceOnly == true,
      preserveAspectRatio = app.preserveAspectRatio == true,
    }
  end
  return res
end

local function normalisePath(filepath)
  return tostring(filepath or ""):gsub("\\", "/")
end

local function dirname(filepath)
  filepath = normalisePath(filepath)
  return filepath:match("(.*/)[^/]*$") or ""
end

local function hasImageExtension(filepath)
  local ext = normalisePath(filepath):match("%.([^.]+)$")
  if not ext then return false end
  return IMAGE_EXTENSIONS[string.lower(ext)] == true
end

local function getImageList(path)
  local dirPath = normalisePath(path)
  if dirPath == "" then return {} end
  watchedImagePaths[dirPath] = true

  local files = FS:findFiles(dirPath, "*.*", -1, true, false) or {}
  local entriesByName = {}

  for _, filepath in ipairs(files) do
    local normalisedPath = normalisePath(filepath)
    if hasImageExtension(normalisedPath) then
      local fileName = normalisedPath:match("([^/]+)$") or ""
      local baseName = fileName:match("(.+)%.([^.]+)$")
      if baseName and baseName ~= "" then
        local stem, suffix = baseName:match("^(.*)(_blur)$")
        if suffix == "_blur" and stem and stem ~= "" then
          local entry = entriesByName[stem] or {}
          entry.blur = normalisedPath
          entriesByName[stem] = entry
        else
          local entry = entriesByName[baseName] or {}
          entry.normal = normalisedPath
          entriesByName[baseName] = entry
        end
      end
    end
  end

  local orderedNames = {}
  for name, _ in pairs(entriesByName) do
    table.insert(orderedNames, name)
  end
  table.sort(orderedNames)

  local result = {}
  for _, name in ipairs(orderedNames) do
    local entry = entriesByName[name]
    if entry and (entry.normal or entry.blur) then
      table.insert(result, entry)
    end
  end

  return result
end

local function startsWithPath(filepath, prefix)
  filepath = normalisePath(filepath)
  prefix = normalisePath(prefix)
  return prefix ~= "" and string.startswith(filepath, prefix)
end

local function runtimeExtOf(filepath)
  local ext = normalisePath(filepath):match("%.([^./]+)$")
  return ext and string.lower(ext) or ""
end

local function isRuntimeStatType(filepath)
  return runtimeStatExts[runtimeExtOf(filepath)] == true
end

local function isRuntimeStyleType(filepath)
  return runtimeStyleExts[runtimeExtOf(filepath)] == true
end

local function isRuntimeUnderIncludes(filepath)
  for _, prefix in ipairs(runtimeBundleIncludes) do
    if startsWithPath(filepath, prefix) then return true end
  end
  return false
end

local function isRuntimeBundled(filepath)
  if not isRuntimeUnderIncludes(filepath) then return false end
  for _, prefix in ipairs(runtimeBundleExcludes) do
    if startsWithPath(filepath, prefix) then return false end
  end
  return true
end

local function shouldServeRuntimeFile(filepath)
  if not isRuntimeUnderIncludes(filepath) then return false end
  if not isRuntimeStatType(filepath) then return false end
  return (not isRuntimeBundled(filepath)) or isRuntimeStyleType(filepath)
end

local function setUiRuntimeBundled(cfg)
  if type(cfg) ~= "table" then return end
  if type(cfg.includes) == "table" then runtimeBundleIncludes = cfg.includes end
  if type(cfg.excludes) == "table" then runtimeBundleExcludes = cfg.excludes end
end

local function buildImageListsChangedPayload(files)
  local changedPathsByName = {}
  local changedFiles = {}

  for _, v in pairs(files or {}) do
    local filename = normalisePath(v.filename)
    local matched = false
    for watchedPath, _ in pairs(watchedImagePaths) do
      if startsWithPath(filename, watchedPath) then
        changedPathsByName[watchedPath] = true
        matched = true
      end
    end
    if matched then
      table.insert(changedFiles, filename)
    end
  end

  local changedPaths = {}
  for watchedPath, _ in pairs(changedPathsByName) do
    table.insert(changedPaths, watchedPath)
  end
  table.sort(changedPaths)

  return {
    paths = changedPaths,
    files = changedFiles,
  }
end

local function fileMatchesApp(filepath, app)
  if not app then return false end
  filepath = normalisePath(filepath)
  if filepath == "" then return false end

  if app.jsSource and filepath == normalisePath(app.jsSource) then return true end
  if app.appJsonPath and filepath == normalisePath(app.appJsonPath) then return true end
  if app.vueFile and filepath == normalisePath(app.vueFile) then return true end

  if app.appJsonPath and startsWithPath(filepath, dirname(app.appJsonPath)) then return true end
  if app.vueFile and startsWithPath(filepath, dirname(app.vueFile)) then return true end

  return false
end

local function buildUiAppsChangedPayload(files)
  local changedFiles = {}
  local appMatches = {}
  local appMatchesList = {}
  local appsByName = {}

  if extensions.ui_apps and extensions.ui_apps.getUIAppsData then
    appsByName = extensions.ui_apps.getUIAppsData() or {}
  end

  for _, v in pairs(files or {}) do
    local filename = normalisePath(v.filename)
    if string.startswith(filename, "/ui/modules/apps/") then
      table.insert(changedFiles, filename)
      for appName, app in pairs(appsByName) do
        if fileMatchesApp(filename, app) then
          appMatches[appName] = {
            appName = app.appName,
            directive = app.directive,
            folder = app.folder,
            appJsonPath = app.appJsonPath,
            jsSource = app.jsSource,
            vueFile = app.vueFile,
            hasAppVue = app.hasAppVue == true,
            hasAppJs = app.hasAppJs == true,
          }
        end
      end
    end
  end

  for _, app in pairs(appMatches) do
    table.insert(appMatchesList, app)
  end

  return {
    files = changedFiles,
    apps = appMatchesList,
  }
end

local function onFilesChanged(files)
  local modModulesChanged = false
  local vueModsChanged = false
  local uiAppsChanged = false
  for _,v in pairs(files) do
    if not modModulesChanged and string.startswith(v.filename, "/ui/modModules/") then
      sendUIModules()
      modModulesChanged = true
    end
    if not vueModsChanged and string.startswith(v.filename, "/ui/ui-vue/mods/") then
      guihooks.trigger("UiModsChanged")
      vueModsChanged = true
    end
    if string.startswith(v.filename, "/ui/modules/apps/") then
      uiAppsChanged = true
    end
    local fname = normalisePath(v.filename)
    if shouldServeRuntimeFile(fname) then
      if v.type == "deleted" then
        runtimeFileMtimes[fname] = nil
        runtimeFileRevs[fname] = (runtimeFileRevs[fname] or 0) + 1
        guihooks.trigger("UiRuntimeFileChanged", { path = fname, rev = runtimeFileRevs[fname], change = "deleted" })
      else
        local stat = FS:stat(v.filename)
        local mtime = stat and (stat.modtime or stat.filetime or stat.createtime) or 0
        if mtime ~= runtimeFileMtimes[fname] then
          runtimeFileMtimes[fname] = mtime
          runtimeFileRevs[fname] = (runtimeFileRevs[fname] or 0) + 1
          guihooks.trigger("UiRuntimeFileChanged", { path = fname, rev = runtimeFileRevs[fname], change = v.type or "modified" })
        end
      end
    end
  end
  if uiAppsChanged then
    guihooks.trigger("UiAppsChanged", buildUiAppsChangedPayload(files))
  end
  local imageListsPayload = buildImageListsChangedPayload(files)
  if #imageListsPayload.paths > 0 then
    guihooks.trigger("UiImageListChanged", imageListsPayload)
  end
end

local function getUiRuntimeRevisions()
  return runtimeFileRevs
end

-- for manual file reloads
local function bumpUiRuntimeRevision(path)
  if type(path) ~= "string" then return 0 end
  runtimeFileRevs[path] = (runtimeFileRevs[path] or 0) + 1
  return runtimeFileRevs[path]
end

local function getUiRuntimeFileList(withMtime)
  local result = {}
  for _, root in ipairs(runtimeBundleIncludes) do
    local searchRoot = root:gsub("/$", "")
    local found = FS:findFiles(searchRoot, "*.*", -1, true, false) or {}
    for _, filepath in ipairs(found) do
      -- parens truncate normalisePath's gsub tuple (string, count) to just the string
      local path = (normalisePath(filepath))
      if shouldServeRuntimeFile(path) then
        if withMtime then
          local stat = FS:stat(filepath)
          local mtime = stat and (stat.modtime or stat.filetime or stat.createtime) or 0
          runtimeFileMtimes[path] = mtime
          table.insert(result, { path = path, mtime = mtime })
        else
          table.insert(result, { path = path })
        end
      end
    end
  end
  return result
end

M.getVueMods = getVueMods
M.getUiApps = getUiApps
M.getImageList = getImageList
M.onFilesChanged = onFilesChanged
M.getUiRuntimeRevisions = getUiRuntimeRevisions
M.bumpUiRuntimeRevision = bumpUiRuntimeRevision
M.getUiRuntimeFileList = getUiRuntimeFileList
M.setUiRuntimeBundled = setUiRuntimeBundled

return M
