-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "ui_photomode_overlays"

local OVERLAY_ROOT = "/ui/ui-vue/src/modules/pause/views/photomode/overlays"

local OVERLAY_JSON = "overlay.json"
local OVERLAY_THUMB = "overlay.png"
local IMAGE_EXTENSIONS = { png = true, jpg = true, jpeg = true, svg = true, webp = true }

local LIVERY_TEXTURE_ROOT = "/art/dynamicDecals/textures"
local LIVERY_SIDECAR_EXT = ".dynDecalTexture.json"

local cachedOverlays = nil
local discoveryRequested = false
local cacheStamp = 0 -- for cache invalidation

local function isEmpty(s)
  return s == nil or s == ""
end

local function splitPath(fullPath)
  local dir, file, ext = path.splitWithoutExt(fullPath)
  return dir, file, ext
end

local function computeEditable(overlayJsonPath)
  if type(FS.getOriginArchivePathRelative) == "function" then
    local originArchive = FS:getOriginArchivePathRelative(overlayJsonPath)
    if originArchive ~= nil and originArchive ~= "" then
      return false
    end
  end

  if type(FS.getFileRealPath) ~= "function" or type(FS.getUserPath) ~= "function" then
    return false
  end

  local realPath = FS:getFileRealPath(overlayJsonPath)
  local userPath = FS:getUserPath()
  if isEmpty(realPath) or isEmpty(userPath) then
    return false
  end

  return string.startswith(realPath, userPath)
end

local function isImageFile(filename)
  local _, _, ext = splitPath(filename)
  if isEmpty(ext) then
    return false
  end
  return IMAGE_EXTENSIONS[string.lower(ext)] == true
end

local function listOverlayFolderImages(folderPath)
  local images = {}
  local files = FS:findFiles(folderPath, "*.*", 0, true, false) or {}
  for _, filepath in ipairs(files) do
    local _, file, ext = splitPath(filepath)
    if not isEmpty(file) and not isEmpty(ext) then
      local bareName = file .. "." .. ext
      if bareName ~= OVERLAY_THUMB and isImageFile(bareName) then
        table.insert(images, bareName)
      end
    end
  end
  table.sort(images)
  return images
end

local function readOverlayAt(folderPath, folderId)
  local overlayJsonPath = folderPath .. "/" .. OVERLAY_JSON
  if not FS:fileExists(overlayJsonPath) then
    return nil, "overlay.json_missing"
  end

  local data = jsonReadFile(overlayJsonPath)
  if type(data) ~= "table" then
    return nil, "overlay.json_invalid"
  end

  if tonumber(data.version) == nil then
    return nil, "overlay.json_missing_version"
  end
  if type(data.name) ~= "string" or data.name == "" then
    return nil, "overlay.json_missing_name"
  end
  if type(data.layers) ~= "table" then
    data.layers = {}
  end

  data.id = folderId
  data.images = listOverlayFolderImages(folderPath)
  data.editable = computeEditable(overlayJsonPath)
  data.folderPath = folderPath
  data.hasThumbnail = FS:fileExists(folderPath .. "/" .. OVERLAY_THUMB)
  data.ts = cacheStamp
  data.name = data.name or data.id
  data.name = _tr(data.name)

  return data
end

local function bumpCacheStamp()
  -- avoid identical stamps for saves within one second
  local nextStamp = math.floor((os.time() or 0) * 1000)
  if nextStamp <= cacheStamp then
    nextStamp = cacheStamp + 1
  end
  cacheStamp = nextStamp
end

local function discover()
  bumpCacheStamp()
  local overlays = {}
  local seenIds = {}

  local candidates = FS:findFiles(OVERLAY_ROOT, OVERLAY_JSON, -1, true, false) or {}
  for _, overlayJsonPath in ipairs(candidates) do
    local folderPath = string.match(overlayJsonPath, "(.+)/" .. OVERLAY_JSON .. "$")
    if folderPath then
      local folderId = string.match(folderPath, "([^/]+)$")
      if folderId and not seenIds[folderId] then
        seenIds[folderId] = true
        local entry, reason = readOverlayAt(folderPath, folderId)
        if entry then
          table.insert(overlays, entry)
        else
          log("W", logTag, "skipping overlay '" .. tostring(folderId) .. "' (" .. folderPath .. "): " .. tostring(reason))
        end
      end
    end
  end

  table.sort(overlays, function(a, b)
    return tostring(a.name or a.id) < tostring(b.name or b.id)
  end)

  return overlays
end

local function getCachedOverlays()
  if cachedOverlays == nil then
    cachedOverlays = discover()
  end
  return cachedOverlays
end

local function findOverlayById(list, id)
  for _, entry in ipairs(list or {}) do
    if entry.id == id then
      return entry
    end
  end
  return nil
end

local function invalidateAndBroadcast()
  cachedOverlays = nil
  guihooks.trigger("PhotomodeOverlaysChanged")
end

local function userFolderPathFor(id)
  return OVERLAY_ROOT .. "/" .. id
end

local function isValidOverlayId(id)
  if type(id) ~= "string" or id == "" then
    return false
  end
  return string.match(id, "^[%w%-_]+$") ~= nil
end

local function copyOverlayAssets(sourceEntry, destFolder)
  if type(FS.directoryCreate) == "function" then
    FS:directoryCreate(destFolder, true)
  end

  local sourceFolder = sourceEntry.folderPath
  local overlayJsonSrc = sourceFolder .. "/" .. OVERLAY_JSON
  local overlayJsonDst = destFolder .. "/" .. OVERLAY_JSON
  if not FS:copyFile(overlayJsonSrc, overlayJsonDst) then
    return false, "copy_overlay_json_failed"
  end

  local thumbSrc = sourceFolder .. "/" .. OVERLAY_THUMB
  if FS:fileExists(thumbSrc) then
    FS:copyFile(thumbSrc, destFolder .. "/" .. OVERLAY_THUMB)
  end

  for _, imageName in ipairs(sourceEntry.images or {}) do
    local srcPath = sourceFolder .. "/" .. imageName
    local dstPath = destFolder .. "/" .. imageName
    if FS:fileExists(srcPath) and not FS:copyFile(srcPath, dstPath) then
      return false, "copy_asset_failed:" .. imageName
    end
  end

  return true
end

function M.discover()
  cachedOverlays = discover()
  return cachedOverlays
end

function M.getOverlays()
  return getCachedOverlays()
end

function M.saveOverlay(id, payload)
  if type(id) ~= "string" or id == "" then
    return { ok = false, reason = "invalid_id" }
  end
  if type(payload) ~= "table" then
    return { ok = false, reason = "invalid_payload" }
  end

  local overlays = getCachedOverlays()
  local entry = findOverlayById(overlays, id)
  if not entry then
    return { ok = false, reason = "not_found" }
  end
  if entry.editable ~= true then
    return { ok = false, reason = "not_editable" }
  end

  local overlayJsonPath = entry.folderPath .. "/" .. OVERLAY_JSON
  local toWrite = {}
  for k, v in pairs(payload) do
    toWrite[k] = v
  end
  toWrite.id = nil
  toWrite.images = nil
  toWrite.editable = nil
  toWrite.folderPath = nil

  local writeOk = jsonWriteFile(overlayJsonPath, toWrite, true)
  if not writeOk then
    return { ok = false, reason = "write_failed" }
  end

  invalidateAndBroadcast()
  return { ok = true }
end

function M.createOverlay(destId, payload)
  if not isValidOverlayId(destId) then
    return { ok = false, reason = "invalid_dest_id" }
  end

  local overlays = getCachedOverlays()
  if findOverlayById(overlays, destId) then
    return { ok = false, reason = "dest_id_exists" }
  end

  local destFolder = userFolderPathFor(destId)
  if type(FS.directoryCreate) == "function" then
    FS:directoryCreate(destFolder, true)
  end

  local toWrite = {
    version = 1,
    name = destId,
    author = "",
    layers = {},
  }
  if type(payload) == "table" then
    if tonumber(payload.version) ~= nil then toWrite.version = tonumber(payload.version) end
    if type(payload.name) == "string" and payload.name ~= "" then toWrite.name = payload.name end
    if type(payload.author) == "string" then toWrite.author = payload.author end
    if type(payload.layers) == "table" then toWrite.layers = payload.layers end
  end

  local overlayJsonPath = destFolder .. "/" .. OVERLAY_JSON
  if not jsonWriteFile(overlayJsonPath, toWrite, true) then
    return { ok = false, reason = "write_failed" }
  end

  invalidateAndBroadcast()
  return { ok = true, id = destId }
end

function M.cloneOverlay(sourceId, destId)
  if type(sourceId) ~= "string" or sourceId == "" then
    return { ok = false, reason = "invalid_source_id" }
  end
  if not isValidOverlayId(destId) then
    return { ok = false, reason = "invalid_dest_id" }
  end

  local overlays = getCachedOverlays()
  local sourceEntry = findOverlayById(overlays, sourceId)
  if not sourceEntry then
    return { ok = false, reason = "source_not_found" }
  end

  if findOverlayById(overlays, destId) then
    return { ok = false, reason = "dest_id_exists" }
  end

  local destFolder = userFolderPathFor(destId)
  local ok, reason = copyOverlayAssets(sourceEntry, destFolder)
  if not ok then
    return { ok = false, reason = reason or "clone_failed" }
  end

  invalidateAndBroadcast()
  return { ok = true, id = destId }
end

function M.renameOverlay(sourceId, destId, newName)
  if type(sourceId) ~= "string" or sourceId == "" then
    return { ok = false, reason = "invalid_source_id" }
  end
  if not isValidOverlayId(destId) then
    return { ok = false, reason = "invalid_dest_id" }
  end

  local overlays = getCachedOverlays()
  local sourceEntry = findOverlayById(overlays, sourceId)
  if not sourceEntry then
    return { ok = false, reason = "source_not_found" }
  end
  if sourceEntry.editable ~= true then
    return { ok = false, reason = "not_editable" }
  end

  local effectiveName = sourceEntry.name or sourceId
  if type(newName) == "string" and newName ~= "" then
    effectiveName = newName
  end

  if destId == sourceId then
    if effectiveName == sourceEntry.name then
      return { ok = true, id = sourceId }
    end
    local payload = {
      version = sourceEntry.version,
      name = effectiveName,
      author = sourceEntry.author,
      layers = sourceEntry.layers or {},
    }
    local res = M.saveOverlay(sourceId, payload)
    if type(res) == "table" and res.ok then
      res.id = sourceId
    end
    return res
  end

  if findOverlayById(overlays, destId) then
    return { ok = false, reason = "dest_id_exists" }
  end

  local destFolder = userFolderPathFor(destId)
  local ok, reason = copyOverlayAssets(sourceEntry, destFolder)
  if not ok then
    return { ok = false, reason = reason or "rename_failed" }
  end

  local newOverlayJson = destFolder .. "/" .. OVERLAY_JSON
  local merged = jsonReadFile(newOverlayJson)
  if type(merged) ~= "table" then merged = {} end
  merged.name = effectiveName
  merged.id = nil
  merged.images = nil
  merged.editable = nil
  merged.folderPath = nil
  merged.hasThumbnail = nil
  merged.ts = nil
  if not jsonWriteFile(newOverlayJson, merged, true) then
    local srcFolder = sourceEntry.folderPath
    FS:removeFile(newOverlayJson)
    if srcFolder ~= destFolder and type(FS.directoryRemove) == "function" then
      FS:directoryRemove(destFolder)
    end
    return { ok = false, reason = "write_failed" }
  end

  local oldFolder = sourceEntry.folderPath
  FS:removeFile(oldFolder .. "/" .. OVERLAY_JSON)
  local oldThumb = oldFolder .. "/" .. OVERLAY_THUMB
  if FS:fileExists(oldThumb) then
    FS:removeFile(oldThumb)
  end
  for _, imageName in ipairs(sourceEntry.images or {}) do
    FS:removeFile(oldFolder .. "/" .. imageName)
  end
  if type(FS.directoryRemove) == "function" then
    FS:directoryRemove(oldFolder)
  end

  invalidateAndBroadcast()
  return { ok = true, id = destId }
end

function M.listUiApps()
  local apps = {}
  if type(ui_apps) ~= "table" or type(ui_apps.getUIAppsData) ~= "function" then
    return apps
  end

  local data = ui_apps.getUIAppsData() or {}
  for appName, info in pairs(data) do
    local css = info.css or {}
    local preview = ""
    for _, p in ipairs(info.previews or {}) do
      if type(p) == "string" and p ~= "" then
        preview = p
        break
      end
    end

    table.insert(apps, {
      appName = info.appName or appName,
      displayName = info.name or info.appName or appName,
      description = info.description or "",
      category = info.category or "",
      preview = preview,
      photomode = info.photomode == true,
      css = {
        left = tostring(css.left or "0px"),
        top = tostring(css.top or "0px"),
        width = tostring(css.width or "320px"),
        height = tostring(css.height or "48px"),
      },
    })
  end

  table.sort(apps, function(a, b)
    if a.photomode ~= b.photomode then
      return a.photomode == true
    end
    return tostring(a.displayName or a.appName) < tostring(b.displayName or b.appName)
  end)
  return apps
end

function M.listLiveryGraphics()
  local categories = {}
  local byTag = {}
  local tagOrder = {}
  local untagged = {}

  local files = FS:findFiles(LIVERY_TEXTURE_ROOT, "*.png\t*.jpg\t*.jpeg", -1, true, false) or {}
  for _, filepath in ipairs(files) do
    local _, file, ext = splitPath(filepath)
    if not isEmpty(file) and not isEmpty(ext) then
      local item = { name = file, label = file, path = filepath }

      local tags = nil
      local sidecar = filepath .. LIVERY_SIDECAR_EXT
      if FS:fileExists(sidecar) then
        local data = jsonReadFile(sidecar)
        if type(data) == "table" and type(data.tags) == "table" then
          tags = data.tags
        end
      end

      if tags and #tags > 0 then
        for _, tag in ipairs(tags) do
          local key = tostring(tag)
          if not byTag[key] then
            byTag[key] = { value = key, label = key, items = {} }
            table.insert(tagOrder, key)
          end
          table.insert(byTag[key].items, item)
        end
      else
        table.insert(untagged, item)
      end
    end
  end

  table.sort(tagOrder, function(a, b) return string.lower(a) < string.lower(b) end)
  for _, key in ipairs(tagOrder) do
    local cat = byTag[key]
    table.sort(cat.items, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
    table.insert(categories, cat)
  end

  if #untagged > 0 then
    table.sort(untagged, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
    table.insert(categories, { value = "others", label = "Others", items = untagged })
  end

  return categories
end

function M.deleteOverlay(id)
  if type(id) ~= "string" or id == "" then
    return { ok = false, reason = "invalid_id" }
  end

  local overlays = getCachedOverlays()
  local entry = findOverlayById(overlays, id)
  if not entry then
    return { ok = false, reason = "not_found" }
  end
  if entry.editable ~= true then
    return { ok = false, reason = "not_editable" }
  end

  local folder = entry.folderPath
  FS:removeFile(folder .. "/" .. OVERLAY_JSON)
  local thumbPath = folder .. "/" .. OVERLAY_THUMB
  if FS:fileExists(thumbPath) then
    FS:removeFile(thumbPath)
  end
  for _, imageName in ipairs(entry.images or {}) do
    FS:removeFile(folder .. "/" .. imageName)
  end
  if type(FS.directoryRemove) == "function" then
    FS:directoryRemove(folder)
  end

  invalidateAndBroadcast()
  return { ok = true }
end

function M.onFilesChanged(files)
  if type(files) ~= "table" then return end
  for _, v in pairs(files) do
    local filename = v and v.filename
    if type(filename) == "string" and string.startswith(filename, OVERLAY_ROOT .. "/") then
      invalidateAndBroadcast()
      return
    end
  end
end

function M.onExtensionLoaded()
  cachedOverlays = nil
  discoveryRequested = false
end

function M.onExtensionUnloaded()
  cachedOverlays = nil
end

function M.onUiReady()
  if not discoveryRequested then
    discoveryRequested = true
    getCachedOverlays()
  end
end

return M
