-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local im = ui_imgui
local imUtils = require("ui/imguiUtils")
local ffi = require('ffi')
local bit = require('bit')

local terrainMaterialTextureSetPath = "art/terrains/main.materials.json"

local terrainMaterialEditorWindowName = "terrainMaterialEditor"
local materialEditorWindowSize = nil
local materialEditorMapThumbnailSize = im.ImVec2(48,48)
local terrainMtlProxy
local terrainMtlCopyProxy
local fontSize

local NotificationState_Ok = 0
local NotificationState_ErrorMtlNameFirstCharIsNumber = 1
local NotificationState_ErrorMtlNameIsEmpty = 2
local NotificationState_ErrorMissingTexture = 5
local notificationState = 0 -- 0: all good, 1: mat name's first char must not be a number, 2: material name must not be empty

local importState = {
  levelPath = nil,
  materials = {},
  selected = {},
  rename = {},
  renamePtrs = {}
}

local terrainMaterialTextureSetProperties = {
  {property = "baseTexSize", name = "Base Texture Size", tooltip = "Sets the expected dimensions of textures used in this slot (must match texture dimensions)"},
  {property = "macroTexSize", name = "Macro Texture Size", tooltip = "Sets the expected dimensions of textures used in this slot (must match texture dimensions)"},
  {property = "detailTexSize", name = "Detail Texture Size", tooltip = "Sets the expected dimensions of textures used in this slot (must match texture dimensions)"}
}

if not scenetree.terrainMatEditor_PersistMan then
  local persistenceMgr = PersistenceManager()
  persistenceMgr:registerObject('terrainMatEditor_PersistMan')
end

local v1MaterialTextureSetMaps = {
  {title = "Base Color", mapIdentifier = "baseColor", defaultOpen = true},
  {title = "Normal", mapIdentifier = "normal", defaultOpen = false},
  {title = "Roughness", mapIdentifier = "roughness", defaultOpen = false},
  {title = "Ambient Occlusion", mapIdentifier = "ao", defaultOpen = false},
  {title = "Height", mapIdentifier = "height", defaultOpen = false},
}

local bulkChange = {
  file = nil,
  name = nil,
  map = nil,
  ext = nil,
  textures = nil
}

local NotificationState_ErrorMaterialAlreadyExists = 3
local NotificationState_ErrorInvalidChars = 4

local lastValidation = { errors = {}, warnings = {} }

local function _resolvePath(p)
  if not p or p == "" then return "" end
  if not string.startswith(p, "/") and FS:fileExists("/" .. p) then
    return "/" .. p
  end
  return p
end

local validationCache = {
  stamp = 0,
  byKey = {},
}

local function invalidateValidationCache()
  validationCache.stamp = validationCache.stamp + 1
end

local function _isValidInternalName(name)
  if not name or name == "" then
    return false, NotificationState_ErrorMtlNameIsEmpty, "Material name must not be empty."
  end
  if name:match("^%d") then
    return false, NotificationState_ErrorMtlNameFirstCharIsNumber, "First character must not be a number."
  end
  if not name:match("^[A-Za-z_][A-Za-z0-9_]*$") then
    return false, NotificationState_ErrorInvalidChars, "Name must match ^[A-Za-z_][A-Za-z0-9_]*$ (letters/digits/underscore; must not start with a digit)."
  end
  return true
end

local function _internalNameTaken(name, currentMatId)
  for _, mtl in pairs(editor_terrainEditor.getMaterialsInJson()) do
    if mtl and mtl.internalName == name then
      if currentMatId and mtl.material and mtl.material.getId and mtl.material:getId() == currentMatId then
        -- ok
      else
        return true
      end
    end
  end

  -- Check live objects too
  local existing = scenetree.findObject(name)
  if existing and existing.getClassName and existing:getClassName() == "TerrainMaterial" then
    if currentMatId and existing.getId and existing:getId() == currentMatId then
      return false
    end
    return true
  end

  return false
end

local function _parsePoint2I(s)
  if not s or s == "" then return nil, nil end
  local x, y = string.match(s, "(-?%d+)%s+(-?%d+)")
  if x and y then return tonumber(x), tonumber(y) end
  return nil, nil
end

local function _readTexSetSizes(terrainBlock)
  local name = terrainBlock:getField("materialTextureSet", 0)
  if not name or name == "" then
    return nil, "TerrainBlock.materialTextureSet is empty."
  end

  local texSet = scenetree.findObject(name)
  if not texSet then
    return nil, "TerrainMaterialTextureSet object not found: " .. tostring(name)
  end

  local bx, by = _parsePoint2I(texSet:getField("baseTexSize", 0))
  local mx, my = _parsePoint2I(texSet:getField("macroTexSize", 0))
  local dx, dy = _parsePoint2I(texSet:getField("detailTexSize", 0))

  if not bx or not by or not mx or not my or not dx or not dy then
    return nil, "TerrainMaterialTextureSet has invalid size fields (base/macro/detail)."
  end

  return {
    obj = texSet,
    base = { bx, by },
    macro = { mx, my },
    detail = { dx, dy }
  }, nil
end

local function _getTexObj(path)
  local rp = _resolvePath(path or "")
  if rp == "" then return nil, rp end
  local tex = editor.getTempTextureObj(rp)
  return tex, rp
end

local function _texIsLoaded(tex)
  if not tex then return false end
  if not tex.format or not tex.size or not tex.size.x or not tex.size.y then return false end
  if tex.format == "no_format" then return false end
  if tex.size.x <= 0 or tex.size.y <= 0 then return false end
  return true
end

local smAllowedFormats = {
  color = {
    GFXFormatR8G8B8 = true,
    GFXFormatR8G8B8A8 = true,
    GFXFormatR8G8B8X8 = true,
    GFXFormatR8G8B8A8_SRGB = true,
    GFXFormatR8G8B8X8_SRGB = true,
  },
  normal = {
    GFXFormatR8G8B8 = true,
    GFXFormatR8G8B8A8 = true,
    GFXFormatR8G8B8X8 = true,
  },
  data = {
    GFXFormatR8 = true,
  }
}

local function _isPow2(n)
  return n and n > 0 and bit.band(n, n - 1) == 0
end

local function _isPngPath(p)
  if not p or p == "" then return false end
  return string.endswith(p:lower(), ".png")
end

local function _slotCategoryForGroup(groupId)
  if groupId == "baseColor" then return "color" end
  if groupId == "normal" then return "normal" end
  return "data" -- roughness/ao/height
end

local function _validateTexSetSizes(errors, warnings, sizes)
  local function checkOne(label, sz)
    local w, h = sz[1], sz[2]
    if not w or not h then
      table.insert(errors, "TerrainMaterialTextureSet " .. label .. " size is missing.")
      return
    end
    if w <= 0 or h <= 0 then
      table.insert(errors, "TerrainMaterialTextureSet " .. label .. " size must be > 0.")
    end
    if not _isPow2(w) or not _isPow2(h) then
      table.insert(errors, string.format("TerrainMaterialTextureSet %s size is not power-of-two: %dx%d", label, w, h))
    end
  end
  checkOne("baseTexSize", sizes.base)
  checkOne("macroTexSize", sizes.macro)
  checkOne("detailTexSize", sizes.detail)
end

local function _validatePngOnly(warnings, groupTitle, slotTitle, resolvedPath)
  if not resolvedPath or resolvedPath == "" then return end
  if not _isPngPath(resolvedPath) then
    table.insert(warnings, string.format("%s %s should be a PNG (.png). Got: %s", groupTitle, slotTitle, resolvedPath))
  end
end

local function _allowedFormatsList(category)
  local allowed = smAllowedFormats[category]
  if not allowed then return nil end

  local list = {}
  for fmt, ok in pairs(allowed) do
    if ok then table.insert(list, tostring(fmt)) end
  end
  table.sort(list)
  return table.concat(list, ", ")
end

local function _validateFormat(warnings, groupTitle, slotTitle, category, tex)
  if not tex or not tex.format then return end
  local fmt = tex.format
  local allowed = smAllowedFormats[category]

  if allowed and not allowed[fmt] then
    local expected = _allowedFormatsList(category) or tostring(category)
    table.insert(
      warnings,
      string.format(
        "%s %s has not recommended format %s (expected: %s).",
        groupTitle, slotTitle, tostring(fmt), expected
      )
    )
  end
end

local function _warnRange(warnings, label, v, minV, maxV)
  if v == nil then return end
  if v < minV or v > maxV then
    table.insert(warnings, string.format("%s out of range [%.3f..%.3f]: %.3f", label, minV, maxV, v))
  end
end

local function _parseFloat2(str)
  if not str or str == "" then return nil, nil end
  local a, b = string.match(str, "([%+%-]?[%d%.eE]+)%s+([%+%-]?[%d%.eE]+)")
  if a and b then return tonumber(a), tonumber(b) end
  return nil, nil
end

local function _parseFloat4(str)
  if not str or str == "" then return nil end
  local a,b,c,d = string.match(str, "([%+%-]?[%d%.eE]+)%s+([%+%-]?[%d%.eE]+)%s+([%+%-]?[%d%.eE]+)%s+([%+%-]?[%d%.eE]+)")
  if a and b and c and d then return { tonumber(a), tonumber(b), tonumber(c), tonumber(d) } end
  return nil
end

local function _checkDistancesOrder(warnings, label, arr4)
  if not arr4 then return end
  for i=1,4 do
    if arr4[i] and arr4[i] < 0 then
      table.insert(warnings, label .. " contains negative value: " .. tostring(arr4[i]))
      return
    end
  end
  if not (arr4[1] <= arr4[2] and arr4[2] <= arr4[3] and arr4[3] <= arr4[4]) then
    table.insert(warnings, label .. " is not ordered (expected StartFadeIn <= Near <= Far <= EndFadeOut).")
  end
end

local function _validateV15NumericRanges(warnings, proxy)
  local a1,a2 = _parseFloat2(proxy.material:getField("macroDistAtten", 0))
  _warnRange(warnings, "macroDistAtten.x", a1, 0, 1)
  _warnRange(warnings, "macroDistAtten.y", a2, 0, 1)

  local b1,b2 = _parseFloat2(proxy.material:getField("detailDistAtten", 0))
  _warnRange(warnings, "detailDistAtten.x", b1, 0, 1)
  _warnRange(warnings, "detailDistAtten.y", b2, 0, 1)

  _checkDistancesOrder(warnings, "macroDistances", _parseFloat4(proxy.material:getField("macroDistances", 0)))
  _checkDistancesOrder(warnings, "detailDistances", _parseFloat4(proxy.material:getField("detailDistances", 0)))

  for _, group in ipairs(v1MaterialTextureSetMaps) do
    local gid = group.mapIdentifier
    local mx,my = _parseFloat2(proxy.material:getField(string.format("%sMacroStrength", gid), 0))
    _warnRange(warnings, string.format("%sMacroStrength.x", gid), mx, 0, 1)
    _warnRange(warnings, string.format("%sMacroStrength.y", gid), my, 0, 1)
    local dx,dy = _parseFloat2(proxy.material:getField(string.format("%sDetailStrength", gid), 0))
    _warnRange(warnings, string.format("%sDetailStrength.x", gid), dx, 0, 1)
    _warnRange(warnings, string.format("%sDetailStrength.y", gid), dy, 0, 1)
  end
end

local function _validateCurrentMaterialProxyInternal(proxy)
  local errors, warnings = {}, {}
  if not proxy or not proxy.material then return errors, warnings end

  local name = ffi.string(proxy.nameInput or "")
  local ok, state, msg = _isValidInternalName(name)
  if not ok then
    notificationState = state
    table.insert(errors, msg)
  end
  local curId = proxy.material and proxy.material.getId and proxy.material:getId() or nil
  if name ~= "" and _internalNameTaken(name, curId) then
    notificationState = NotificationState_ErrorMaterialAlreadyExists
    table.insert(errors, "A TerrainMaterial with this name already exists.")
  end

  local terrain = editor_terrainEditor.getTerrainBlock()
  local isV15 = terrain and terrain:getField("materialTextureSet", 0) ~= ""

  if not terrain then
    table.insert(errors, "No TerrainBlock found in scene; cannot validate terrain materials.")
    return errors, warnings
  end

  if isV15 then
    local sizes, sizesErr = _readTexSetSizes(terrain)
    if not sizes then
      table.insert(errors, sizesErr or "TerrainMaterialTextureSet could not be read.")
      return errors, warnings
    end

    _validateTexSetSizes(errors, warnings, sizes)

    local function validateSlot(groupTitle, groupId, slotTitle, slotKey, expectedSize)
      local prop = string.format("%s%sTex", groupId, slotKey)
      local raw = proxy.material:getField(prop, 0) or ""

      if raw == "" then
        table.insert(errors, string.format("%s %s texture is empty.", groupTitle, slotTitle))
        return
      end

      local tex, resolved = _getTexObj(raw)

      _validatePngOnly(warnings, groupTitle, slotTitle, resolved)

      -- must be loadable
      if not _texIsLoaded(tex) then
        table.insert(errors, string.format("%s %s texture not found: %s", groupTitle, slotTitle, resolved))
        return
      end

      if expectedSize and expectedSize[1] and expectedSize[2] then
        local w, h = tex.size.x, tex.size.y
        if w ~= expectedSize[1] or h ~= expectedSize[2] then
          table.insert(errors, string.format(
            "%s %s texture has size %dx%d, expected %dx%d (TerrainMaterialTextureSet). Path: %s",
            groupTitle, slotTitle, w, h, expectedSize[1], expectedSize[2], resolved
          ))
        end
      end

      local category = _slotCategoryForGroup(groupId)
      _validateFormat(warnings, groupTitle, slotTitle, category, tex)
    end

    for _, group in ipairs(v1MaterialTextureSetMaps) do
      local gid = group.mapIdentifier
      local gtitle = group.title
      validateSlot(gtitle, gid, "Base",   "Base",   sizes.base)
      validateSlot(gtitle, gid, "Macro",  "Macro",  sizes.macro)
      validateSlot(gtitle, gid, "Detail", "Detail", sizes.detail)
    end

    _validateV15NumericRanges(warnings, proxy)

  else
    local function checkLegacy(label, path)
      path = path or ""
      if path == "" then return end
      local resolved = _resolvePath(path)
      local tex = editor.getTempTextureObj(resolved)
      if not _texIsLoaded(tex) then
        table.insert(warnings, label .. " texture not found: " .. resolved)
        return
      end
    end

    checkLegacy("Diffuse", proxy.diffuseMap)
    checkLegacy("Normal",  proxy.normalMap)
    checkLegacy("Detail",  proxy.detailMap)
    checkLegacy("Macro",   proxy.macroMap)
  end

  return errors, warnings
end

local function validateMaterialProxy(proxy, opts)
  opts = opts or {}
  local useCache = (opts.useCache ~= false)

  if not proxy or not proxy.material then
    local res = { ok = true, errors = {}, warnings = {} }
    return res, res.errors, res.warnings
  end

  local key = opts.cacheKey
  if not key then
    key = proxy.uniqueID
  end
  if not key then
    local mid = (proxy.material and proxy.material.getId) and proxy.material:getId() or 0
    local iname = proxy.internalName or (proxy.material.getInternalName and proxy.material:getInternalName()) or ""
    key = tostring(iname) .. "-" .. tostring(mid)
  end
  key = "mat|" .. tostring(key)

  if useCache then
    local entry = validationCache.byKey[key]
    if entry and entry.lastStamp == validationCache.stamp then
      return entry, entry.errors, entry.warnings
    end
  end

  local temp = proxy
  if proxy.nameInput == nil then
    temp = {
      material = proxy.material,
      internalName = proxy.internalName,
      uniqueID = proxy.uniqueID,
      nameInput = im.ArrayChar(128, proxy.material:getInternalName() or proxy.internalName or ""),
      diffuseMap = proxy.diffuseMap,
      normalMap  = proxy.normalMap,
      detailMap  = proxy.detailMap,
      macroMap   = proxy.macroMap,
    }
  end

  local errors, warnings = _validateCurrentMaterialProxyInternal(temp)

  local entry = {
    ok = (#errors == 0),
    errors = errors,
    warnings = warnings,
    lastStamp = validationCache.stamp
  }

  if useCache then
    validationCache.byKey[key] = entry
  end

  return entry, errors, warnings
end

local function drawValidationIconForProxy(mtlProxy)
  local res = validateMaterialProxy(mtlProxy, { useCache = true })
  if not res then return false end

  -- Only show icon when there is something to show.
  local hasErr = (not res.ok) and res.errors and #res.errors > 0
  local hasWarn = res.warnings and #res.warnings > 0
  if not hasErr and not hasWarn then
    return false
  end
  local iconSize = im.ImVec2(16 * im.uiscale[0], 16 * im.uiscale[0])

  local function showTooltip()
    im.BeginTooltip()
    im.PushTextWrapPos(500)
    if hasErr then
      im.TextUnformatted("Errors:")
      for _, e in ipairs(res.errors) do im.BulletText(e) end
    end
    if hasWarn then
      if hasErr then im.Separator() end
      im.TextUnformatted("Warnings:")
      for _, w in ipairs(res.warnings) do im.BulletText(w) end
    end
    im.PopTextWrapPos()
    im.EndTooltip()
  end

  local warnCol = im.ImVec4(1.00, 0.85, 0.30, 1.0)
  local errCol  = im.ImVec4(1.00, 0.25, 0.25, 1.0)
  if hasErr then
    editor.uiIconImageButton(editor.icons.error, iconSize, errCol)
  elseif hasWarn then
    editor.uiIconImageButton(editor.icons.warning, iconSize, warnCol)
  end

  if im.IsItemHovered() then
    showTooltip()
  end

  return true
end

local function drawValidationSummary(errors, warnings)
  if errors and #errors > 0 then
    im.Separator()
    im.TextColored(im.ImVec4(1.0, 0.2, 0.2, 1.0), "Validation Errors:")
    for _, e in ipairs(errors) do im.BulletText(e) end
  end
  if warnings and #warnings > 0 then
    im.Separator()
    im.TextColored(im.ImVec4(1.0, 0.75, 0.2, 1.0), "Validation Warnings:")
    for _, w in ipairs(warnings) do im.BulletText(w) end
  end
end

local function loadTerrainMaterialsFromJson(path)
  if not FS:fileExists(path) then return {} end

  local data = jsonReadFile(path)
  if not data then return {} end

  local materials = {}

  for _, entry in pairs(data) do
    if entry.class == "TerrainMaterial" then
      table.insert(materials, entry)
    end
  end

  table.sort(materials, function(a, b)
    return (a.internalName or "") < (b.internalName or "")
  end)

  return materials
end

local function getLinkTarget(path)
  if not path or path == "" then return nil end

  local linkPath = path .. ".link"
  if FS:fileExists(linkPath) then
    local data = jsonReadFile(linkPath)
    if data and data.path then
      return data.path, true
    end
  end

  return path, false
end

local function createLink(dstPath, targetPath)
  local linkData = {
    path = targetPath,
    type = "normal"
  }

  jsonWriteFile(dstPath .. ".link", linkData, true)
end

local function ensureSlash(p)
  if not p or p == "" then return "" end
  return string.endswith(p, "/") and p or (p .. "/")
end

local function remapTexturePath(srcPath)
  if not srcPath or srcPath == "" then return "" end

  local target, isLink = getLinkTarget(srcPath)
  if not target then return srcPath end

  local levelRoot = ensureSlash(editor_terrainEditor.getVars().levelPath)

  local rel = srcPath
  rel = rel:gsub("^/levels/[^/]+/", "")
  rel = rel:gsub("^/", "")

  local dstPath = levelRoot .. rel

  local dir = string.match(dstPath, "(.+/)")
  if dir and not FS:directoryExists(dir) then
    FS:directoryCreate(dir, true)
  end

  if not FS:fileExists(dstPath) and not FS:fileExists(dstPath .. ".link") then
    createLink(dstPath, target)
  end

  return dstPath
end

local function helpTooltip(text)
  if im.IsItemHovered() then
    im.BeginTooltip()
    im.PushTextWrapPos(420)
    im.TextUnformatted(text)
    im.PopTextWrapPos()
    im.EndTooltip()
  end
end

local upgradeFileFormatMaterials = {}

local function setProperty(propertyName, value, obj)
  obj = obj or terrainMtlCopyProxy.material
  obj:setField(propertyName, 0, value)
  invalidateValidationCache()
end

local function propertyUndo(actionData)
  local obj = scenetree.findObjectById(actionData.objectId)
  if obj then
    if type(actionData.property) == "table" then
      if type(actionData.oldValue) == "table" then
        for k, prop in ipairs(actionData.property) do
          setProperty(prop, actionData.oldValue[k], obj)
        end
      else
        for k, prop in ipairs(actionData.property) do
          setProperty(prop, actionData.oldValue, obj)
        end
      end
      return
    end
    setProperty(actionData.property, actionData.oldValue, obj)
  end
end

local function propertyRedo(actionData)
  local obj = scenetree.findObjectById(actionData.objectId)
  if obj then
    if type(actionData.property) == "table" then
      if type(actionData.newValue) == "table" then
        for k, prop in ipairs(actionData.property) do
          setProperty(prop, actionData.newValue[k], obj)
        end
      else
        for k, prop in ipairs(actionData.property) do
          setProperty(prop, actionData.newValue, obj)
        end
      end
      return
    end
    setProperty(actionData.property, actionData.newValue, obj)
  end
end

local function setPropertyWithUndo(property, value, undoActionId, obj)
  obj = obj or terrainMtlCopyProxy.material
  local oldValue
  if type(property) == "table" then
    if type(value) == "table" then
      oldValue = {}
      for k,v in ipairs(property) do
        table.insert(oldValue, obj:getField(v, 0))
      end
    else
      oldValue = obj:getField(property[1], 0)
    end
  else
    oldValue = obj:getField(property, 0)
  end

  editor.history:commitAction(
    "SetTerrainMaterialProperty_" .. (undoActionId or property),
    {
      objectId = obj:getId(),
      property = property,
      newValue = value,
      oldValue = oldValue
    },
    propertyUndo,
    propertyRedo
  )
  invalidateValidationCache()
end

local function inputText(label, propertyName, widthMod)
  if label then
    im.TextUnformatted(label)
    im.SameLine()
  end
  im.PushItemWidth(im.GetContentRegionAvailWidth() + (widthMod or 0))
  editor.uiInputText(
    "##" .. propertyName .. tostring(0),
    editor.getTempCharPtr(terrainMtlCopyProxy.material:getField(propertyName, 0)),
    nil,
    im.InputTextFlags_AutoSelectAll,
    nil,
    nil,
    editor.getTempBool_BoolBool(false)
  )
  im.PopItemWidth()

  if editor.getTempBool_BoolBool() == true then
    setPropertyWithUndo(propertyName, editor.getTempCharPtr())
  end
end

local function deleteMapButton(label, propertyName)
  local inputWidgetHeight = math.ceil(im.GetFontSize()) + 2 * im.GetStyle().FramePadding.y
  im.PushID1(propertyName .. '_RemoveMapButton')
  if editor.uiIconImageButton(
    editor.icons.material_texturemap_remove,
    im.ImVec2(inputWidgetHeight, inputWidgetHeight)
  ) then
    setPropertyWithUndo(propertyName, "")
  end
  im.tooltip("Remove " .. label)
  im.PopID()
end

local function widgetTexture(map, property, widgetName)
  local propertyName = string.format(property, map)
  im.TextUnformatted(widgetName)
  im.SameLine()
  im.TextDisabled("(?)")
  helpTooltip(
    "Texture source path.\n\n" ..
    "- Source textures are loaded and packed into cached textures.\n" ..
    "- Pixel dimensions MUST match TerrainMaterialTextureSet Base/Macro/Detail sizes.\n" ..
    "- If missing or wrong size, packing can fail or terrain renders black.\n"
  )
  if editor.uiButtonRightAlign("Bulk Change Texture", nil, true, "bulkChangeTexture_" .. map .. property) then
    editor_fileDialog.openFile(
      function(data)
        bulkChange = {
          file = data.filepath,
          property = property,
          textures = {}
        }

        local regexRule = "([a-zA-Z0-9_]+)_([a-zA-Z_]+).(%w+)$"

        bulkChange.name, bulkChange.map, bulkChange.ext = string.match(data.filepath, regexRule)

        local filePaths = FS:findFiles(data.path, "*", 0, true, false)
        local files = {}
        for k,v in ipairs(filePaths) do
          local name, map, ext = string.match(v, regexRule)
          local asset = {file = v, name = name, map = map, ext = ext}
          table.insert(files, asset)

          if name == bulkChange.name and ext == bulkChange.ext then
            bulkChange.textures[map] = asset
          end
        end

        editor.openModalWindow("bulkChangeTexturesModal")
      end,
      {{"PNG", {".png"}}, {"Any files", "*"}},
      false,
      getMissionPath() .. "art/terrains/",
      true
  )
end
  im.tooltip("Automatically change all texture paths for a new set according to file name")

  local val = terrainMtlCopyProxy.material:getField(propertyName, 0)
  local texture = editor.getTempTextureObj(val)

  local function openFileDialog()
    editor_fileDialog.openFile(
      function(data)
        if val ~= data.filepath then
          setPropertyWithUndo(propertyName, data.filepath)
        end
      end,
      {{"PNG", {".png"}}, {"Any files", "*"}},
      false,
      string.match(val, "(.+/).+$") or "/",
      true
    )
  end

  local inputWidgetHeight = math.ceil(im.GetFontSize()) + 2 * im.GetStyle().FramePadding.y

  -- im.TextUnformatted(val)
  inputText("Path", propertyName, -(2 * inputWidgetHeight * im.uiscale[0] + 2 * im.GetStyle().ItemSpacing.x))
  im.SameLine()
  if editor.uiIconImageButton(
    editor.icons.folder,
    im.ImVec2(inputWidgetHeight, inputWidgetHeight)
  ) then
    openFileDialog()
  end
  im.tooltip("Browse for new texture")
  im.SameLine()
  deleteMapButton(widgetName, propertyName)

  local texture = editor.getTempTextureObj(val)
  local size = im.ImVec2(128, 128)

  im.PushID1(propertyName)
  if im.ImageButton(
    "##imageButton1",
    texture.texId,
    size,
    im.ImVec2Zero,
    im.ImVec2One,
    im.ImColorByRGB(255,255,255,255).Value,
    im.ImColorByRGB(255,255,255,255).Value
  ) then
    openFileDialog()
  end
  im.tooltip("Browse for new texture")
  im.PopID()
end

local function widgetFloat(propertyName, widgetName)
  im.TextUnformatted(widgetName)
  im.SameLine()
  im.PushItemWidth(im.GetContentRegionAvailWidth())
  if editor.uiInputFloat(
    "##" .. propertyName,
    editor.getTempFloat_StringString(terrainMtlCopyProxy.material:getField(propertyName, 0)),
    float_step or 1,
    float_step_fast or 128,
    string_format or "%.0f",
    nil,
    editor.getTempBool_BoolBool(false)
  ) then
    setProperty(propertyName, editor.getTempFloat_StringString())
  end

  if editor.getTempBool_BoolBool() == true then
    setPropertyWithUndo(propertyName, editor.getTempFloat_StringString())
  end
  im.PopItemWidth()
end

local function widgetTextureSize(map, property, widgetName, tooltip)
  local propertyName = string.format(property, map)
  im.TextUnformatted(widgetName)
  im.SameLine()
  im.TextDisabled("(?)")
  helpTooltip(tooltip or "World mapping scale in meters. This is NOT the pixel size. Pixel size is controlled by TerrainMaterialTextureSet.")
  im.SameLine()
  im.PushItemWidth(im.GetContentRegionAvailWidth())
  editor.uiInputFloat(
    "##" .. propertyName,
    editor.getTempFloat_StringString(terrainMtlCopyProxy.material:getField(propertyName, 0)),
    float_step or 1,
    float_step_fast or 128,
    string_format or "%.0f",
    nil,
    editor.getTempBool_BoolBool(false)
  )

  if editor.getPreference("terrainEditor.terrainMaterialLibrary.keepSizeForAllMaps") == true then
    tooltip = (tooltip and (tooltip .. "\n\n") or "") .. "Setting 'keep size for all maps' is enabled.\nIf you change this value, '" .. widgetName .. "' will change for all groups (Base, Normal, Roughness, Ambient Occlusion, Height)."
  end
  if tooltip and im.IsItemHovered() then
    im.BeginTooltip()
    im.PushTextWrapPos(300)
    im.TextUnformatted(tooltip)
    im.PopTextWrapPos()
    im.EndTooltip()
  end

  if editor.getTempBool_BoolBool() == true then
    if editor.getPreference("terrainEditor.terrainMaterialLibrary.keepSizeForAllMaps") == true then
      local properties = {}
      for k,v in ipairs(v1MaterialTextureSetMaps) do
        table.insert(properties, string.format(property, v.mapIdentifier))
      end
      setPropertyWithUndo(properties, editor.getTempFloat_StringString(), property)
    else
      setPropertyWithUndo(propertyName, editor.getTempFloat_StringString())
    end
  end
  im.PopItemWidth()
end

local function widgetFloat2(propertyName, widgetName, obj, format, tooltip)
  obj = obj or terrainMtlCopyProxy.material
  im.TextUnformatted(widgetName)
  im.SameLine()
  im.PushItemWidth(im.GetContentRegionAvailWidth())
  editor.uiInputFloat2(
    "##" .. propertyName,
    editor.getTempFloatArray2_StringString(obj:getField(propertyName, 0)),
    format or "%.2f",
    nil,
    editor.getTempBool_BoolBool(false)
  )
  if tooltip then im.tooltip(tooltip) end

  if editor.getTempBool_BoolBool() == true then
    setPropertyWithUndo(propertyName, editor.getTempFloatArray2_StringString(), nil, obj)
  end
  im.PopItemWidth()
end

local function widgetInt2(propertyName, widgetName, obj, tooltip)
  obj = obj or terrainMtlCopyProxy.material
  im.TextUnformatted(widgetName)
  im.SameLine()
  im.PushItemWidth(im.GetContentRegionAvailWidth())
  editor.uiInputInt2(
    "##" .. propertyName,
    editor.getTempIntArray2_StringString(obj:getField(propertyName, 0)),
    nil,
    editor.getTempBool_BoolBool(false)
  )
  if tooltip then im.tooltip(tooltip) end

  if editor.getTempBool_BoolBool() == true then
    setPropertyWithUndo(propertyName, editor.getTempIntArray2_StringString(), nil, obj)
  end
  im.PopItemWidth()
end

local function widgetDistances(propertyName, widgetName)
  im.TextUnformatted(widgetName)
  local tempBoolPtr = editor.getTempBool_BoolBool(false)

  local floatArr4 = editor.getTempFloatArray4_StringString(terrainMtlCopyProxy.material:getField(propertyName, 0))
  local changed = false

  im.TextUnformatted("Start Fade In")
  local posX = im.GetCursorPosX()
  im.SameLine()
  im.SetCursorPosX(posX + 90)
  im.PushItemWidth(im.GetContentRegionAvailWidth())
  if editor.uiInputFloat(
    "##startFadeIn_" .. propertyName,
    editor.getTempFloat_NumberNumber(floatArr4[0]),
    float_step or 1,
    float_step_fast or 128,
    string_format or "%.0f",
    nil,
    tempBoolPtr
  ) then
    changed = true
    floatArr4[0] = editor.getTempFloat_NumberNumber()
  end
  im.PopItemWidth()
  im.tooltip("Distance to begin fading into the Near value")

  im.TextUnformatted("Near")
  im.SameLine()
  im.SetCursorPosX(posX + 90)
  im.PushItemWidth(im.GetContentRegionAvailWidth())
  if editor.uiInputFloat(
    "##near_" .. propertyName,
    editor.getTempFloat_NumberNumber(floatArr4[1]),
    float_step or 1,
    float_step_fast or 128,
    string_format or "%.0f",
    nil,
    tempBoolPtr
  ) then
    changed = true
    floatArr4[1] = editor.getTempFloat_NumberNumber()
  end
  im.PopItemWidth()
  im.tooltip("Distance of near value")

  im.TextUnformatted("Far")
  im.SameLine()
  im.SetCursorPosX(posX + 90)
  im.PushItemWidth(im.GetContentRegionAvailWidth())
  if editor.uiInputFloat(
    "##far_" .. propertyName,
    editor.getTempFloat_NumberNumber(floatArr4[2]),
    float_step or 1,
    float_step_fast or 128,
    string_format or "%.0f",
    nil,
    tempBoolPtr
  ) then
    changed = true
    floatArr4[2] = editor.getTempFloat_NumberNumber()
  end
  im.PopItemWidth()
  im.tooltip("Distance of far value")

  im.TextUnformatted("End Fade Out")
  im.SameLine()
  im.SetCursorPosX(posX + 90)
  im.PushItemWidth(im.GetContentRegionAvailWidth())
  if editor.uiInputFloat(
    "##endFadeOut_" .. propertyName,
    editor.getTempFloat_NumberNumber(floatArr4[3]),
    float_step or 1,
    float_step_fast or 128,
    string_format or "%.0f",
    nil,
    tempBoolPtr
  ) then
    changed = true
    floatArr4[3] = editor.getTempFloat_NumberNumber()
  end
  im.PopItemWidth()
  im.tooltip("Distance where the far value has completed faded")

  if tempBoolPtr[0] == true then
    setPropertyWithUndo(propertyName, editor.getTempFloatArray4_StringString())
  elseif changed == true then
    setPropertyWithUndo(propertyName, editor.getTempFloatArray4_StringString())
  end
end

local function editMaterial(mtlProxy)
  -- if the previous edited material proxy was a newly created material and was not saved, then delete it as it was a temporary material
  if terrainMtlCopyProxy and terrainMtlCopyProxy.material and terrainMtlCopyProxy.isNew then
    terrainMtlCopyProxy.material:deleteObject()
    terrainMtlCopyProxy = nil
  end

  if not mtlProxy then
    -- create a new TerrainMaterial object
    local newName = editor_terrainEditor.getUniqueMtlName("NewMaterial")
    local newMtl = TerrainMaterial()
    local pid = newMtl:getOrCreatePersistentID()
    local fullName = newName .. "-" .. pid
    newMtl:setInternalName(newName)
    newMtl:setField("name", 0, fullName)
    newMtl:setField("persistentId", 0, pid)
    mtlProxy = editor_terrainEditor.createMaterialProxy(-1, pid, newMtl, newName, false, true)
    mtlProxy.isNew = true
    mtlProxy.fileName = editor_terrainEditor.getVars().levelPath .. editor_terrainEditor.getMatFilePath()
    mtlProxy.uniqueID = fullName
    newMtl:setFileName(mtlProxy.fileName)
  end

  terrainMtlProxy = mtlProxy
  terrainMtlCopyProxy = editor_terrainEditor.createMaterialProxy(-1, mtlProxy.persistentId, mtlProxy.material, mtlProxy.internalName)
  terrainMtlCopyProxy = editor_terrainEditor.copyMaterialProxyWithInputs(terrainMtlCopyProxy)
  terrainMtlCopyProxy.isNew = terrainMtlProxy.isNew
  notificationState = NotificationState_Ok
  invalidateValidationCache()
end

local function duplicateSelectedMaterial()
  if not terrainMtlProxy or not terrainMtlProxy.material then return end

  local srcProxy = terrainMtlProxy
  local srcMat = srcProxy.material

  local newName = editor_terrainEditor.getUniqueMtlName((srcProxy.internalName or "Material") .. "_copy")
  local newMtl = TerrainMaterial()
  newMtl:setInternalName(newName)

  local fileName = srcProxy.fileName
  if not fileName or fileName == "" then
    fileName = editor_terrainEditor.getVars().levelPath .. editor_terrainEditor.getMatFilePath()
  end
  newMtl:setFileName(fileName)

  local newPid = newMtl:getOrCreatePersistentID()
  local fullName = newName .. "-" .. newPid
  newMtl:setField("name", 0, fullName)
  newMtl:setField("persistentId", 0, newPid)
  newMtl:registerObject(fullName)

  local fields = srcMat:getFields()
  for fieldName, _ in pairs(fields) do
    if fieldName ~= "name" and fieldName ~= "persistentId" and fieldName ~= "internalName" and fieldName ~= "fileName" then
      local data = srcMat:getField(fieldName, 0)
      if data ~= nil then
        newMtl:setField(fieldName, 0, data)
      end
    end
  end

  scenetree.terrEd_PersistMan:setDirty(newMtl, fileName)
  editor_terrainEditor.setMaterialsDirty()
  editor_terrainEditor.saveTerrainAndMaterials()

  editor_terrainEditor.updateMaterialLibrary()
  editor_terrainEditor.updatePaintMaterialProxies()

  local newProxy = nil
  for _, mtl in pairs(editor_terrainEditor.getMaterialsInJson()) do
    if mtl and (mtl.persistentId == newPid or mtl.internalName == newName) then
      newProxy = mtl
      break
    end
  end

  if not newProxy or not newProxy.material then
    editor.logError("Failed to duplicate terrain material: could not resolve new proxy after library refresh: " .. tostring(newName))
    return
  end

  editMaterial(newProxy)
  invalidateValidationCache()
end

local function importMaterialFromOtherLevel()
  importState = {
    levelPath = nil,
    materials = {},
    selected = {},
    rename = {},
    renamePtrs = {},
    levels = {}
  }

  local infoFiles = FS:findFiles("/levels/", "info.json", 1, true, false) or {}

  for _, filename in ipairs(infoFiles) do
    local dir = string.match(filename, "(.+/)info%.json$")
    if dir then
      local info = jsonReadFile(filename) or {}

      local name = string.match(dir, ".+/([^/]+)/$") or dir

      table.insert(importState.levels, {
        path = dir,
        name = name
      })
    end
  end

  table.sort(importState.levels, function(a,b)
    return tostring(a.name) < tostring(b.name)
  end)

  editor.openModalWindow("importTerrainMaterialsModal")
end

local function applyMtlChanges()
  local forbiddenName = false
  local newName = ffi.string(terrainMtlCopyProxy.nameInput)
  local oldUniqueID = terrainMtlProxy.uniqueID
  local pid = terrainMtlCopyProxy.persistentId or terrainMtlCopyProxy.material:getOrCreatePersistentID()
  local newUniqueID = newName .. "-" .. pid
  -- we have a new name
  if terrainMtlCopyProxy.internalName ~= newName then
    for _, mtl in ipairs(editor_terrainEditor.getMaterialsInJson()) do
      if mtl.internalName == newName then
        forbiddenName = true
        break
      end
    end
  end

  -- copy the material object from list to current material proxy
  terrainMtlProxy.material = terrainMtlCopyProxy.material

  if not forbiddenName then
    if terrainMtlCopyProxy.fileName == "" then editor.logError("Empty filename for terrain material: "  .. terrainMtlProxy.internalName) end
    -- we must delete the entry from the file first, because if the name changed, the old material will remain in the file
    if not terrainMtlCopyProxy.isNew then
      if oldUniqueID and oldUniqueID ~= "" then
        terrainMtlCopyProxy.material:setField("name", 0, oldUniqueID)
      end
      scenetree.terrEd_PersistMan:removeObjectFromFileLua(terrainMtlCopyProxy.material, terrainMtlCopyProxy.fileName)
    end
    terrainMtlCopyProxy.internalName = newName
    terrainMtlCopyProxy.persistentId = pid
    terrainMtlCopyProxy.uniqueID = newUniqueID
    terrainMtlCopyProxy.material:setField("persistentId", 0, pid)
    terrainMtlCopyProxy.material:setField("name", 0, newUniqueID)
    terrainMtlProxy.material:setInternalName(newName)
    terrainMtlProxy.internalName = newName
    terrainMtlProxy.persistentId = pid
    terrainMtlProxy.uniqueID = newUniqueID
  else
    editor.logWarn("Cannot set the terrain material name " .. newName .. ", already taken.")
    terrainMtlCopyProxy.nameInput = im.ArrayChar(32, terrainMtlCopyProxy.internalName)
    terrainMtlProxy.internalName = terrainMtlCopyProxy.internalName
  end

  -- version 1 terrain material
  if editor_terrainEditor.getTerrainBlock() then
    if editor_terrainEditor.getTerrainBlock():getField('materialTextureSet', 0) == "" then
      -- set the material properties from the edited material proxy
      terrainMtlProxy.material:setDiffuseMap(terrainMtlCopyProxy.diffuseMap)
      terrainMtlProxy.material:setDiffuseSize(terrainMtlCopyProxy.diffuseSizeInput[0])
      terrainMtlProxy.material:setNormalMap(terrainMtlCopyProxy.normalMap)
      terrainMtlProxy.material:setDetailMap(terrainMtlCopyProxy.detailMap)
      terrainMtlProxy.material:setMacroMap(terrainMtlCopyProxy.macroMap)
      terrainMtlProxy.material:setDetailSize(terrainMtlCopyProxy.detailSizeInput[0])
      terrainMtlProxy.material:setDetailStrength(terrainMtlCopyProxy.detailStrengthInput[0])
      terrainMtlProxy.material:setDetailDistance(terrainMtlCopyProxy.detailDistanceInput[0])
      terrainMtlProxy.material:setMacroSize(terrainMtlCopyProxy.macroSizeInput[0])
      terrainMtlProxy.material:setMacroDistance(terrainMtlCopyProxy.macroDistanceInput[0])
      terrainMtlProxy.material:setMacroStrength(terrainMtlCopyProxy.macroStrengthInput[0])
      terrainMtlProxy.material:setUseSideProjection(terrainMtlCopyProxy.useSideProjectionInput[0])
      terrainMtlProxy.material:setParallaxScale(terrainMtlCopyProxy.parallaxScaleInput[0])
    else -- version 1.5 terrain material
      for k, map in ipairs(v1MaterialTextureSetMaps) do
        terrainMtlProxy.material:setField(string.format("%sBaseTex", map.mapIdentifier), 0, terrainMtlCopyProxy.material:getField(string.format("%sBaseTex", map.mapIdentifier), 0))
        terrainMtlProxy.material:setField(string.format("%sBaseTexSize", map.mapIdentifier), 0, terrainMtlCopyProxy.material:getField(string.format("%sBaseTexSize", map.mapIdentifier), 0))

        terrainMtlProxy.material:setField(string.format("%sMacroTex", map.mapIdentifier), 0, terrainMtlCopyProxy.material:getField(string.format("%sMacroTex", map.mapIdentifier), 0))
        terrainMtlProxy.material:setField(string.format("%sMacroTexSize", map.mapIdentifier), 0, terrainMtlCopyProxy.material:getField(string.format("%sMacroTexSize", map.mapIdentifier), 0))
        terrainMtlProxy.material:setField(string.format("%sMacroStrength", map.mapIdentifier), 0, terrainMtlCopyProxy.material:getField(string.format("%sMacroStrength", map.mapIdentifier), 0))

        terrainMtlProxy.material:setField(string.format("%sDetailTex", map.mapIdentifier), 0, terrainMtlCopyProxy.material:getField(string.format("%sDetailTex", map.mapIdentifier), 0))
        terrainMtlProxy.material:setField(string.format("%sDetailTexSize", map.mapIdentifier), 0, terrainMtlCopyProxy.material:getField(string.format("%sDetailTexSize", map.mapIdentifier), 0))
        terrainMtlProxy.material:setField(string.format("%sDetailStrength", map.mapIdentifier), 0, terrainMtlCopyProxy.material:getField(string.format("%sDetailStrength", map.mapIdentifier), 0))
      end
      terrainMtlProxy.material:setField("macroDistAtten", 0, terrainMtlCopyProxy.material:getField("macroDistAtten", 0))
      terrainMtlProxy.material:setField("detailDistAtten", 0, terrainMtlCopyProxy.material:getField("detailDistAtten", 0))

      --cleanup, removing v1 properties
      terrainMtlProxy.material:setDiffuseMap("")
      terrainMtlProxy.material:setNormalMap("")
      terrainMtlProxy.material:setDetailMap("")
      terrainMtlProxy.material:setMacroMap("")
    end
  end
  terrainMtlProxy.material:setGroundmodelName(terrainMtlCopyProxy.groundmodelName)
  terrainMtlProxy.material:setField("annotation", 0, terrainMtlCopyProxy.material:getField("annotation", 0))

  terrainMtlProxy.groundmodelName = terrainMtlCopyProxy.groundmodelName
  terrainMtlProxy.fileName = terrainMtlCopyProxy.fileName
end

local function terrainMaterialEditor_Accept()
  local _, errors, warnings = validateMaterialProxy(terrainMtlCopyProxy, { useCache = true })
  lastValidation.errors = errors
  lastValidation.warnings = warnings

  if errors and #errors > 0 then
    -- set a reasonable notificationState if not already set by validator
    if notificationState == NotificationState_Ok then
      notificationState = NotificationState_ErrorMissingTexture
    end
    editor.logWarn("Terrain material not saved due to validation errors.")
    return
  end

  local oldMaterialName = terrainMtlCopyProxy.internalName
  local materialName = ffi.string(terrainMtlCopyProxy.nameInput)
  local oldUniqueID = terrainMtlProxy and terrainMtlProxy.uniqueID

  -- check if a material name has been set
  if string.len(materialName) == 0 then
    notificationState = NotificationState_ErrorMtlNameIsEmpty
  else
    local index = -1
    -- find the index if it exists in paint materials
    for i, mtlProxy in ipairs(editor_terrainEditor.getPaintMaterialProxies()) do
      if mtlProxy.internalName == oldMaterialName then
        index = i - 1
        break
      end
    end

    if terrainMtlCopyProxy.isNew then
      local pid = terrainMtlCopyProxy.persistentId or terrainMtlCopyProxy.material:getOrCreatePersistentID()
      terrainMtlCopyProxy.persistentId = pid
      terrainMtlCopyProxy.uniqueID = materialName .. "-" .. pid
      terrainMtlCopyProxy.material:setInternalName(materialName)
      terrainMtlCopyProxy.material:setField("persistentId", 0, pid)
      terrainMtlCopyProxy.material:setField("name", 0, terrainMtlCopyProxy.uniqueID)
      terrainMtlCopyProxy.material:registerObject(terrainMtlCopyProxy.uniqueID)
      editor_terrainEditor.getMaterialsInJson()[terrainMtlCopyProxy.uniqueID] = terrainMtlCopyProxy
    end

    applyMtlChanges()
    if oldUniqueID and oldUniqueID ~= terrainMtlProxy.uniqueID then
      editor_terrainEditor.getMaterialsInJson()[oldUniqueID] = nil
    end
    editor_terrainEditor.getMaterialsInJson()[terrainMtlProxy.uniqueID] = terrainMtlProxy

    -- change the name in the paint materials also and find the index if it exists in there
    for _, mtlProxy in ipairs(editor_terrainEditor.getPaintMaterialProxies()) do
      if mtlProxy.internalName == oldMaterialName then
        mtlProxy.internalName = materialName
        break
      end
    end

    terrainMtlProxy.dirty = true

    if index ~= -1 then
      if editor_terrainEditor.getTerrainBlock() then
        editor_terrainEditor.getTerrainBlock():updateMaterial(index, terrainMtlProxy.internalName)
      end
      terrainMtlProxy.index = index
      editor_terrainEditor.updatePaintMaterialProxies()
    end

    terrainMtlProxy.isNew = nil
    scenetree.terrEd_PersistMan:setDirty(terrainMtlProxy.material, terrainMtlProxy.fileName or "")
    terrainMtlCopyProxy.isNew = nil
    editor_terrainEditor.setMaterialsDirty()
    editor_terrainEditor.setTerrainDirty()
    editor_terrainEditor.saveTerrainAndMaterials()
  end
end

local function materialPropertiesGuiBase()
  im.TextUnformatted("Material Properties")
    im.ShowHelpMarker("When using the Upgraded Material System, all textures must be of the same size specified in the TextureSet properties. \n" ..
    "Base Texture must be in sRGB colorspace. Other textures must be in linear colorspace.\n" ..
    "More info in the Official Documentation (F1)", true)
  im.Separator()
end

local function matNameInputWidget(widthMod)
  im.TextUnformatted("Name")
  im.SameLine()
  im.PushItemWidth(im.GetWindowContentRegionWidth() - (widthMod or 0))
  if im.InputText("##MaterialNameInput", terrainMtlCopyProxy.nameInput, nil, im.flags(im.InputTextFlags_CharsNoBlank)) then
    local firstChar = tonumber(string.sub(ffi.string(terrainMtlCopyProxy.nameInput), 1, 1))
    if firstChar and type(firstChar) == "number" then
      notificationState = 1
    else
      notificationState = 0
    end
  end
  im.PopItemWidth()
end

local function materialPropertiesGuiV0()
  matNameInputWidget()
  im.Separator()

  local childWidth = im.GetItemRectSize().x
  local groundModelName = terrainMtlCopyProxy.groundmodelName
  local groundModelNamesSorted = tableKeys(core_environment.groundModels)
  table.sort(groundModelNamesSorted)
  if not tableContains(groundModelNamesSorted, string.upper(groundModelName)) then groundModelName = "" end
  im.Text("Ground Model:")
  im.SameLine()
  im.PushItemWidth(im.GetContentRegionAvailWidth())
  if im.BeginCombo("##groundModels", groundModelName) then
    for _, gmName in ipairs(groundModelNamesSorted) do
      if im.Selectable1(gmName) then
        notificationState = 0
        terrainMtlCopyProxy.groundmodelName = gmName
      end
    end
    im.EndCombo()
  end
  im.PopItemWidth()
  im.Separator()

  -- diffuse
  im.PushID1("mat_properties_image_button_diffuse")
  if im.ImageButton("##imageButton2", terrainMtlCopyProxy.diffuseMapObj.texId, materialEditorMapThumbnailSize, nil, nil) then
    editor_fileDialog.openFile(
      function(data) editor_terrainEditor.updateMap(terrainMtlCopyProxy, "diffuse", data.filepath) end,
      {{"Any files", "*"}, {"Images", {".png", ".dds", ".jpg"}}, {"DDS", ".dds"}, {"PNG", ".png"}, {"JPG", ".jpg"}},
      false, editor_terrainEditor.getVars().lastPath .. editor_terrainEditor.getTerrainFolder(), true)
  end
  im.PopID()
  if terrainMtlCopyProxy.diffuseMap ~= "" then
    im.tooltip(terrainMtlCopyProxy.diffuseMap)
  end
  editor_terrainEditor.dragDropTarget(terrainMtlCopyProxy, "diffuse")
  im.SameLine()
  im.BeginGroup()
  im.TextUnformatted("Diffuse")
  im.SameLine()
  local removeMapButtonCursorX = childWidth - editor_terrainEditor.getVars().style.ItemInnerSpacing.x - fontSize - editor_terrainEditor.getVars().style.ScrollbarSize
  im.SetCursorPosX(removeMapButtonCursorX)
  if editor.uiIconImageButton(editor.icons.delete, im.ImVec2(fontSize, fontSize)) then
    editor_terrainEditor.removeMap(terrainMtlCopyProxy, "diffuse")
  end
  im.tooltip("Remove diffuse map")
  local cursorPosX = im.GetCursorPosX()
  local itemWidth = childWidth - cursorPosX - editor_terrainEditor.getVars().style.WindowPadding.x / 2 - im.CalcTextSize("Parallax Scale").x - editor_terrainEditor.getVars().style.ItemInnerSpacing.x - editor_terrainEditor.getVars().style.ScrollbarSize
  im.PushItemWidth(itemWidth)
  im.InputFloat("Size##Diffuse", terrainMtlCopyProxy.diffuseSizeInput, 1, 10, "%.0f")
  im.PopItemWidth()
  im.Checkbox("Use Side Projection##Diffuse", terrainMtlCopyProxy.useSideProjectionInput)
  im.EndGroup()
  im.Separator()
  -- macro
  im.PushID1("mat_properties_image_button_macro")
  if im.ImageButton("##imageButton3", terrainMtlCopyProxy.macroMapObj.texId, materialEditorMapThumbnailSize, nil, nil) then
    editor_fileDialog.openFile(
      function(data) editor_terrainEditor.updateMap(terrainMtlCopyProxy, "macro", data.filepath) end,
      {{"Any files", "*"}, {"Images",{".png", ".dds", ".jpg"}}, {"DDS", ".dds"},{"PNG", ".png"},{"JPG", ".jpg"}},
      false, editor_terrainEditor.getVars().lastPath .. editor_terrainEditor.getTerrainFolder(), true)
  end
  im.PopID()
  if terrainMtlCopyProxy.macroMap ~= "" then
    im.tooltip(terrainMtlCopyProxy.macroMap)
  end
  editor_terrainEditor.dragDropTarget(terrainMtlCopyProxy, "macro")
  im.SameLine()
  im.BeginGroup()
  im.TextUnformatted("Macro")
  im.SameLine()
  im.SetCursorPosX(removeMapButtonCursorX)
  if editor.uiIconImageButton(editor.icons.delete, im.ImVec2(fontSize, fontSize)) then
    editor_terrainEditor.removeMap(terrainMtlCopyProxy, "macro")
  end
  im.tooltip("Remove macro map")
  im.PushItemWidth(itemWidth)
  im.InputFloat("Strength##Macro", terrainMtlCopyProxy.macroStrengthInput, 0.01, 0.1, "%.2f")
  im.PopItemWidth()
  im.PushItemWidth(itemWidth)
  im.InputFloat("Size##Macro", terrainMtlCopyProxy.macroSizeInput, 1, 10, "%.0f")
  im.PopItemWidth()
  im.PushItemWidth(itemWidth)
  im.InputFloat("Distance##Macro", terrainMtlCopyProxy.macroDistanceInput, 1, 10, "%.0f")
  im.PopItemWidth()
  im.EndGroup()
  im.Separator()
  -- detail
  im.PushID1("mat_properties_image_button_detail")
  if im.ImageButton("##imageButton4", terrainMtlCopyProxy.detailMapObj.texId, materialEditorMapThumbnailSize, nil, nil) then
    editor_fileDialog.openFile(
      function(data) editor_terrainEditor.updateMap(terrainMtlCopyProxy, "detail", data.filepath) end,
      {{"Any files", "*"}, {"Images", {".png", ".dds", ".jpg"}}, {"DDS", ".dds"}, {"PNG", ".png"},{"JPG", ".jpg"}},
      false, editor_terrainEditor.getVars().lastPath .. editor_terrainEditor.getTerrainFolder(), true)
  end
  im.PopID()
  if terrainMtlCopyProxy.detailMap ~= "" then
    im.tooltip(terrainMtlCopyProxy.detailMap)
  end
  editor_terrainEditor.dragDropTarget(terrainMtlCopyProxy, "detail")
  im.SameLine()
  im.BeginGroup()
  im.TextUnformatted("Detail")
  im.SameLine()
  im.SetCursorPosX(removeMapButtonCursorX)
  if editor.uiIconImageButton(editor.icons.delete, im.ImVec2(fontSize, fontSize)) then
    editor_terrainEditor.removeMap(terrainMtlCopyProxy, "detail")
  end
  im.tooltip("Remove detail map")
  im.PushItemWidth(itemWidth)
  im.InputFloat("Strength##Detail", terrainMtlCopyProxy.detailStrengthInput, 0.01, 0.1, "%.2f")
  im.PopItemWidth()
  im.PushItemWidth(itemWidth)
  im.InputFloat("Size##Detail", terrainMtlCopyProxy.detailSizeInput, 1, 10, "%.0f")
  im.PopItemWidth()
  im.PushItemWidth(itemWidth)
  im.InputFloat("Distance##Detail", terrainMtlCopyProxy.detailDistanceInput, 1, 10, "%.0f")
  im.PopItemWidth()
  im.EndGroup()
  im.Separator()
  -- normal
  im.PushID1("mat_properties_image_button_normal")
  if im.ImageButton("##imageButton5", terrainMtlCopyProxy.normalMapObj.texId, materialEditorMapThumbnailSize, nil, nil) then
    editor_fileDialog.openFile(
      function(data) editor_terrainEditor.updateMap(terrainMtlCopyProxy, "normal", data.filepath) end,
      {{"Any files", "*"}, {"Images", {".png", ".dds", ".jpg"}}, {"DDS", ".dds"}, {"PNG", ".png"}, {"JPG", ".jpg"}},
      false, editor_terrainEditor.getVars().lastPath .. editor_terrainEditor.getTerrainFolder(), true)
  end
  im.PopID()
  if terrainMtlCopyProxy.normalMap ~= "" then
    im.tooltip(terrainMtlCopyProxy.normalMap)
  end
  editor_terrainEditor.dragDropTarget(terrainMtlCopyProxy, "normal")
  im.SameLine()
  im.BeginGroup()
  im.TextUnformatted("Normal")
  im.SameLine()
  im.SetCursorPosX(removeMapButtonCursorX)
  if editor.uiIconImageButton(editor.icons.delete, im.ImVec2(fontSize, fontSize)) then
    editor_terrainEditor.removeMap(terrainMtlCopyProxy, "normal")
  end
  im.tooltip("Remove normal map")
  im.PushItemWidth(itemWidth)
  im.InputFloat("Parallax Scale##Normal", terrainMtlCopyProxy.parallaxScaleInput, 0.01, 0.1, "%.2f")
  im.PopItemWidth()
  im.EndGroup()
  im.Separator()
end

local function terrainMaterialPropertyTreeNode(name, textureMap, defaultOpen)
  if im.CollapsingHeader1(name, defaultOpen == true and im.TreeNodeFlags_DefaultOpen or nil) then
    widgetTexture(textureMap, "%sBaseTex", "Base Texture")
    widgetTextureSize(textureMap, "%sBaseTexSize", "Base Mapping Scale", "Size (in meters) of the Base Texture in the world.")
    im.Separator()
    widgetTexture(textureMap, "%sMacroTex", "Macro Texture")
    widgetTextureSize(textureMap, "%sMacroTexSize", "Macro Mapping Scale", "Size (in meters) of the Macro Texture in the world.")
    widgetFloat2(string.format("%sMacroStrength", textureMap), "Macro Strength", nil, nil, "Strength of the macro texture influence (0.0 - 1.0)")
    im.Separator()
    widgetTexture(textureMap, "%sDetailTex", "Detail Texture")
    widgetTextureSize(textureMap, "%sDetailTexSize", "Detail Mapping Scale", "Size (in meters) of the Detail Texture in the world.")
    widgetFloat2(string.format("%sDetailStrength", textureMap), "Detail Strength", nil, nil, "Strength of the detail texture influence (0.0 - 1.0)")
  end
end

local function doBulkChange()
  local properties = {}
  local values = {}
  for map, asset in pairs(bulkChange.textures) do
    if map == "b" then
      table.insert(properties, string.format(bulkChange.property, "baseColor"))
      table.insert(values, asset.file)
    end
    if map == "nm" then
      table.insert(properties, string.format(bulkChange.property, "normal"))
      table.insert(values, asset.file)
    end
    if map == "r" then
      table.insert(properties, string.format(bulkChange.property, "roughness"))
      table.insert(values, asset.file)
    end
    if map == "ao" then
      table.insert(properties, string.format(bulkChange.property, "ao"))
      table.insert(values, asset.file)
    end
    if map == "h" then
      table.insert(properties, string.format(bulkChange.property, "height"))
      table.insert(values, asset.file)
    end
  end
  setPropertyWithUndo(properties, values, "bulkChange")
  bulkChange = {}
  editor.closeModalWindow("bulkChangeTexturesModal")
end

local function materialPropertiesGuiV1()
  if editor.beginModalWindow("bulkChangeTexturesModal", "Bulk Change Textures") then
    if bulkChange and bulkChange.textures then
      im.TextUnformatted("Found the following textures:")
      im.Dummy(im.ImVec2(0, 10))

      im.Columns(2)
      if bulkChange.textures.b then
        im.TextUnformatted("Base Color")
        im.NextColumn()
        im.TextUnformatted(bulkChange.textures.b.file)
        im.NextColumn()
      end
      if bulkChange.textures.nm then
        im.TextUnformatted("Normal")
        im.NextColumn()
        im.TextUnformatted(bulkChange.textures.nm.file)
        im.NextColumn()
      end
      if bulkChange.textures.r then
        im.TextUnformatted("Roughness")
        im.NextColumn()
        im.TextUnformatted(bulkChange.textures.r.file)
        im.NextColumn()
      end
      if bulkChange.textures.ao then
        im.TextUnformatted("Ambient Occlusion")
        im.NextColumn()
        im.TextUnformatted(bulkChange.textures.ao.file)
        im.NextColumn()
      end
      if bulkChange.textures.h then
        im.TextUnformatted("Height")
        im.NextColumn()
        im.TextUnformatted(bulkChange.textures.h.file)
        im.NextColumn()
      end
      im.Columns(1)
      im.Dummy(im.ImVec2(0, 10))
      im.TextUnformatted("Would you like to bulk change them?")
    end

    if im.Button("Close") then
      bulkChange = {}
      editor.closeModalWindow("bulkChangeTexturesModal")
    end
    im.SameLine()
    if im.Button("Bulk Change") then
      doBulkChange()
    end
  end
  editor.endModalWindow()

  matNameInputWidget()
  im.Separator()

  local groundModelName = terrainMtlCopyProxy.groundmodelName
  local groundModelNamesSorted = tableKeys(core_environment.groundModels)
  table.sort(groundModelNamesSorted)
  if not tableContains(groundModelNamesSorted, string.upper(groundModelName)) then groundModelName = "" end
  im.Text("Ground Model:")
  im.SameLine()
  im.PushItemWidth(im.GetContentRegionAvailWidth())
  if im.BeginCombo("##groundModels", groundModelName) then
    for _, gmName in ipairs(groundModelNamesSorted) do
      if im.Selectable1(gmName) then
        notificationState = 0
        terrainMtlCopyProxy.groundmodelName = gmName
      end
    end
    im.EndCombo()
  end
  im.PopItemWidth()

  im.Separator()
  for i, k in ipairs(v1MaterialTextureSetMaps) do
    terrainMaterialPropertyTreeNode(k.title, k.mapIdentifier, k.defaultOpen)
  end

  im.Separator()
  widgetDistances("macroDistances", "Macro Distances")
  widgetFloat2("macroDistAtten", "Macro Distance Attenuation", nil, nil, "Defines how much the near and far values fade to at the Start Fade In/Out distances (1 = fade to 0, 0 = no fade)")
  im.Separator()
  widgetDistances("detailDistances", "Detail Distances")
  widgetFloat2("detailDistAtten", "Detail Distance Attenuation", nil, nil, "Defines how much the near and far values fade to at the Start Fade In/Out distances (1 = fade to 0, 0 = no fade)")
  im.Separator()
end

local function upgradeTerrainMaterialFileFormat()
  upgradeFileFormatMaterials.oldFile = editor_terrainEditor.getLevelPath() .. "/art/terrains/materials.json"
  upgradeFileFormatMaterials.newFile = editor_terrainEditor.getLevelPath() .. editor_terrainEditor.getMatFilePath()
  upgradeFileFormatMaterials.terrainMaterials = {}
  local terrainMaterials = scenetree.findClassObjects('TerrainMaterial')
  for k,v in ipairs(terrainMaterials) do
    local terrainMaterial = scenetree.findObject(v)
    if terrainMaterial then
      local currentFilename = terrainMaterial:getFileName()
      if currentFilename == editor_terrainEditor.getLevelPath() .. "/art/terrains/materials.json" then
        table.insert(upgradeFileFormatMaterials.terrainMaterials, {
          id = terrainMaterial:getId(),
          name = terrainMaterial:getInternalName()
        })
      end
    end
  end

  editor.openModalWindow("upgradeTerrainMaterialsFileFormatModal")
end

local function onEditorGui()
  if editor.beginWindow(terrainMaterialEditorWindowName, "Terrain Material Library") then

    if editor.beginModalWindow("upgradeTerrainMaterialsFileFormatModal", "Upgrade Terrain Material File Format") then

      if upgradeFileFormatMaterials and upgradeFileFormatMaterials.terrainMaterials then

        im.PushTextWrapPos(im.GetContentRegionAvailWidth())
        im.TextUnformatted("The following Terrain Materials will be moved to a new file using the most recent file format.")
        im.Dummy(im.ImVec2(0, 10))
        im.TextUnformatted("Old file path: " .. upgradeFileFormatMaterials.oldFile)
        im.TextUnformatted("New file path: " .. upgradeFileFormatMaterials.newFile)
        im.PopTextWrapPos()

        im.Dummy(im.ImVec2(0, 10))
        if im.BeginTable('##terrainMaterialsTable', 2) then
          im.TableSetupScrollFreeze(0, 1)
          im.TableSetupColumn('ID')
          im.TableSetupColumn('Name')
          im.TableHeadersRow()
          im.TableNextColumn()
          for k, v in ipairs(upgradeFileFormatMaterials.terrainMaterials) do
            im.TextUnformatted(tostring(v.id))
            im.TableNextColumn()
            im.TextUnformatted(v.name)
            im.TableNextColumn()
          end
        im.EndTable()
        end

        im.Dummy(im.ImVec2(0, 10))
      end

      if im.Button("Close") then
        upgradeFileFormatMaterials = {}
        editor.closeModalWindow("upgradeTerrainMaterialsFileFormatModal")
      end
      im.SameLine()
      if im.Button("Upgrade##upgradeFileFormat") then
        if upgradeFileFormatMaterials and upgradeFileFormatMaterials.terrainMaterials then
          for k,v in ipairs(upgradeFileFormatMaterials.terrainMaterials) do
            local terrainMaterial = scenetree.findObject(v.id)
            if terrainMaterial then
              scenetree.terrainMatEditor_PersistMan:removeObjectFromFileLua(terrainMaterial, upgradeFileFormatMaterials.oldFile)
              terrainMaterial:serializeToNameDictFile(upgradeFileFormatMaterials.newFile)
            end
          end
        end
        upgradeFileFormatMaterials = {}
        editor.logInfo("Terrain Material's file format has been updated. Please check the files in question.")
        editor_terrainEditor.updateMaterialLibrary()
        editor_terrainEditor.checkForTerrainMaterialFileFormat()
        editor_terrainEditor.fixedFileFormat()
        editor.closeModalWindow("upgradeTerrainMaterialsFileFormatModal")
      end
    end
    editor.endModalWindow()

    if editor.beginModalWindow("upgradeTerrainMaterialsModal", "Upgrade Terrain Materials") then
      im.PushTextWrapPos(im.GetContentRegionAvailWidth())
      im.TextUnformatted("This will create a TerrainMaterialTextureSet object and attach it to your Terrain Blocks.")
      im.TextColored(editor.color.warning.Value, [[
DISCLAIMER: The upgraded terrain material system introduces new properties.
Former terrain material properties won't be used by the new system
hence all your terrain materials will be broken.
You'll have to manually update the properties (textures, ...).
]])
      im.Dummy(im.ImVec2(0,10))
      im.TextColored(editor.color.warning.Value, "Once the terrain materials are upgraded you won't be able to fallback to the former system within this editor.")
      im.TextUnformatted("Do not forget to save the level in order to apply the changes that have been made to the TerrainBlock object.")
      im.Dummy(im.ImVec2(0,20))
      if not editor_terrainEditor.getTerrainBlock() then
        im.TextColored(editor.color.warning.Value, "There's no Terrain Block in the scene.")
      end
      im.PopTextWrapPos()

      if im.Button("Close") then
        editor.closeModalWindow("upgradeTerrainMaterialsModal")
      end
      im.SameLine()
      if im.Button("Upgrade##upgradeTerrainMaterials") then
        if editor_terrainEditor.getTerrainBlock() then
          local filename = getMissionPath() .. terrainMaterialTextureSetPath
          local name = string.match(getMissionPath(), "/(.[^/]+)/$") .. "TerrainMaterialTextureSet"

          local textureSet = scenetree.findObject(name)
          if not textureSet then
           textureSet = createObject('TerrainMaterialTextureSet')
          end
          textureSet:setFileName(filename)
          textureSet:setField('name', 0, name)
          textureSet.canSave = true
          textureSet:registerObject(name)
          scenetree.terrainMatEditor_PersistMan:setDirty(textureSet, '')
          editor_terrainEditor.getTerrainBlock():setField('materialTextureSet', 0, name)
          scenetree.terrainMatEditor_PersistMan:saveDirty()
          editor.setDirty()

          -- remove obsolete v1 fields from terrain materials
          for id, mtl in pairs(editor_terrainEditor.getMaterialsInJson()) do
            mtl.material:setDiffuseMap("")
            mtl.material:setNormalMap("")
            mtl.material:setDetailMap("")
            mtl.material:setMacroMap("")

            scenetree.terrEd_PersistMan:setDirty(mtl.material, mtl.fileName or "")
            editor_terrainEditor.setMaterialsDirty()
            editor_terrainEditor.saveTerrainAndMaterials()
          end

          reloadTerrainMaterials()
        end

        editor.closeModalWindow("upgradeTerrainMaterialsModal")
      end
    end
    editor.endModalWindow()
    if editor.beginModalWindow("importTerrainMaterialsModal", "Import Terrain Materials") then

      if not importState.levelPath then
        im.TextUnformatted("Select Source Level")
        im.Separator()

        if im.BeginChild1("##levelList", im.ImVec2(0, 250), true) then
          for _, lvl in ipairs(importState.levels or {}) do
            if im.Selectable1(lvl.name) then
              importState.levelPath = lvl.path

              local matFile = lvl.path .. editor_terrainEditor.getMatFilePath()
              if not FS:fileExists(matFile) then
                matFile = lvl.path .. "/art/terrains/materials.json"
              end

              importState.materials = {}
              importState.selected = {}

              if FS:fileExists(matFile) then
                importState.materials = loadTerrainMaterialsFromJson(matFile)
              else
                editor.logWarn("No terrain materials found for level: " .. tostring(lvl.name))
              end
            end
          end
        end
        im.EndChild()

        if im.Button("Close") then
          importState = {
            levelPath = nil,
            materials = {},
            selected = {},
            rename = {},
            renamePtrs = {},
            levels = {}
          }
          editor.closeModalWindow("importTerrainMaterialsModal")
        end

      else
        im.TextUnformatted("Level: " .. tostring(importState.levelPath))
        im.Separator()

        if im.Button("< Back") then
          importState.levelPath = nil
          importState.materials = {}
          importState.selected = {}
        end

        im.Separator()

        if im.BeginChild1("##materialList", im.ImVec2(0, 250), true) then
          importState.renamePtrs = importState.renamePtrs or {}
          for _, m in ipairs(importState.materials) do
            local key = m.internalName or "unknown"

            local ptr = im.BoolPtr(importState.selected[key] or false)
            if im.Checkbox("##sel_" .. key, ptr) then
              importState.selected[key] = ptr[0]
            end

            im.SameLine()

            im.TextUnformatted(key)
            im.SameLine()

            importState.rename[key] = importState.rename[key] or key

            im.PushItemWidth(150)
            local buf = importState.renamePtrs[key]
            if not buf then
              buf = im.ArrayChar(128, importState.rename[key] or key)
              importState.renamePtrs[key] = buf
            end

            im.InputText("##rename_" .. key, buf)
            importState.rename[key] = ffi.string(buf)
            im.PopItemWidth()
          end
        end
        im.EndChild()

        if im.Button("Cancel") then
          importState = {}
          editor.closeModalWindow("importTerrainMaterialsModal")
        end

        im.SameLine()

        if im.Button("Import") then
          for _, m in ipairs(importState.materials) do
            if importState.selected[m.internalName] then

              local newMtl = TerrainMaterial()

              local baseName = importState.rename[m.internalName] or m.internalName or "Material"
              local newName = editor_terrainEditor.getUniqueMtlName(baseName)
              newMtl:setInternalName(newName)
              for field, value in pairs(m) do
                if field ~= "internalName"
                and field ~= "persistentId"
                and field ~= "class"
                and field ~= "name" then

                  if type(value) == "string" and string.find(field:lower(), "tex") then
                    local newPath = remapTexturePath(value)
                    newMtl:setField(field, 0, newPath)

                  elseif type(value) == "table" then
                    newMtl:setField(field, 0, table.concat(value, " "))
                  else
                    newMtl:setField(field, 0, tostring(value))
                  end
                end
              end

              local fileName = editor_terrainEditor.getVars().levelPath .. editor_terrainEditor.getMatFilePath()
              newMtl:setFileName(fileName)

              local pid = newMtl:getOrCreatePersistentID()

              local fullName = newName .. "-" .. pid

              newMtl:setField("name", 0, fullName)
              newMtl:setInternalName(newName)

              newMtl:registerObject(fullName)

              local proxy = editor_terrainEditor.createMaterialProxy(-1, pid, newMtl, newName, false, false)
              editor_terrainEditor.getMaterialsInJson()[proxy.uniqueID] = proxy

              local pm = scenetree.terrEd_PersistMan or scenetree.terrainMatEditor_PersistMan
              if pm then
                pm:setDirty(newMtl, fileName)
              end
            end
          end

          editor_terrainEditor.setMaterialsDirty()
          editor_terrainEditor.saveTerrainAndMaterials()
          editor_terrainEditor.updateMaterialLibrary()
          editor_terrainEditor.updatePaintMaterialProxies()
          invalidateValidationCache()

          importState = {}
          editor.closeModalWindow("importTerrainMaterialsModal")
        end
      end

    end
    editor.endModalWindow()
    local btnHeight = math.ceil(im.GetFontSize()) + 2
    --TODO: move to terrain.lua api
    fontSize = math.ceil(im.GetFontSize())
    if editor_terrainEditor then editor_terrainEditor.setupVars() end
    materialEditorWindowSize = im.GetWindowSize()

    fontSize = math.ceil(im.GetFontSize())
    if editor_terrainEditor then editor_terrainEditor.setupVars() end
    materialEditorWindowSize = im.GetWindowSize()

    local avail = im.GetContentRegionAvail()

    local statusLineH  = im.GetTextLineHeightWithSpacing()
    local buttonsRowH  = im.GetFrameHeightWithSpacing()
    local sepH         = im.GetStyle().ItemSpacing.y
    local footerPad    = 8 * im.uiscale[0]

    local detailsH = math.floor(140 * im.uiscale[0])

    local footerHeight = statusLineH + sepH + detailsH + sepH + buttonsRowH + footerPad

    local mainSize = im.ImVec2(0, avail.y - footerHeight)
    if mainSize.y < 50 then mainSize.y = 50 end

    if im.BeginChild1("##TerrainMatEditor_MainScroll", mainSize, false) then
      im.Columns(2)

      -- TERRAIN MATERIALS COLUMN
      if im.BeginChild1("Terrain Materials##Child", nil, true) then
        im.TextUnformatted("Material Library")
        im.SameLine()
        -- Add new material
        if editor.uiIconImageButton(editor.icons.add, im.ImVec2(fontSize, fontSize)) then
          editMaterial()
          terrainMtlProxy.dirty = true
          scenetree.terrEd_PersistMan:setDirty(terrainMtlProxy.material, editor_terrainEditor.getVars().levelPath .. editor_terrainEditor.getMatFilePath())
        end
        im.tooltip("Create New Material (edit it on right side panel)")

        im.SameLine()

        -- Duplicate selected material
        im.BeginDisabled(not (terrainMtlProxy and terrainMtlProxy.material))
        if editor.uiIconImageButton(editor.icons.copy or editor.icons.duplicate or editor.icons.content_copy, im.ImVec2(fontSize, fontSize)) then
          duplicateSelectedMaterial()
        end
        im.tooltip("Duplicate Selected Material")
        im.EndDisabled()

        im.SameLine()

        -- Delete selected material
        if editor.uiIconImageButton(editor.icons.delete, im.ImVec2(fontSize, fontSize)) and terrainMtlProxy and terrainMtlProxy.material then
          --TODO: undo
          local index = editor_terrainEditor.getTerrainBlockMaterialIndex(terrainMtlProxy.internalName)
          local canDelete = true

          if index ~= -1 then
            if tableSize(editor_terrainEditor.getPaintMaterialProxies()) == 1 then
              editor.logWarn("Cannot delete terrain material, there must be at least one in the library and terrain block")
              canDelete = false
            else
              if editor_terrainEditor.getTerrainBlock() then
                editor_terrainEditor.getTerrainBlock():removeMaterial(index - 1)
                editor_terrainEditor.setTerrainDirty()
              end
            end
          end

          if canDelete then
            editor_terrainEditor.setMaterialsDirty()
            scenetree.terrEd_PersistMan:removeObjectFromFileLua(terrainMtlProxy.material, terrainMtlProxy.fileName)
            editor_terrainEditor.updatePaintMaterialProxies()
            terrainMtlProxy.material:deleteObject()
            editor_terrainEditor.getMaterialsInJson()[terrainMtlProxy.uniqueID] = nil
            terrainMtlProxy = nil
            terrainMtlCopyProxy = nil
          end
        end
        im.tooltip("Delete Selected Material")

        im.SameLine()
        -- Import material from other level
        if editor.uiIconImageButton(editor.icons.import, im.ImVec2(fontSize, fontSize)) then
          importMaterialFromOtherLevel()
        end
        im.tooltip("Import Material from Other Level")

        im.SameLine()

        local posX = im.GetCursorPosX()
        im.SetCursorPosX(posX + im.GetContentRegionAvailWidth() - ((1 * im.GetStyle().FramePadding.x) + im.CalcTextSize("Reload Terrain Materials").x))
        if im.SmallButton("Reload Terrain Materials") then
          editor.logInfo("Reloading Terrain Materials")
          reloadTerrainMaterials()
        end

        im.Separator()

        local name = ""
        if terrainMtlCopyProxy then
          name = terrainMtlCopyProxy.internalName
        end
        if im.CollapsingHeader1("Terrain Materials", im.TreeNodeFlags_DefaultOpen) then
          local iconW = (fontSize + im.GetStyle().ItemSpacing.x)

          for id, mtl in pairs(editor_terrainEditor.getMaterialsInJson()) do
            -- draw icon first (if any)
            local drewIcon = drawValidationIconForProxy(mtl)
            if drewIcon then
              im.SameLine()
            else
              -- reserve the same horizontal space so names align
              im.Dummy(im.ImVec2(iconW, 1))
              im.SameLine()
            end

            -- selectable uses remaining width
            local label = mtl.internalName .. "##Terrain Materials" .. tostring(id)
            local w = im.GetContentRegionAvailWidth()
            if im.Selectable1(label, name == mtl.internalName, nil, im.ImVec2(w, 0)) then
              editMaterial(mtl)
            end
          end
        end
        im.Separator()

        if editor_terrainEditor.getTerrainBlock() then
          if editor_terrainEditor.getTerrainBlock():getField('materialTextureSet', 0) == "" then
            im.Dummy(im.ImVec2(0,10))
            if im.Button("Upgrade Terrain Materials", im.ImVec2(im.GetContentRegionAvailWidth(), 0)) then
              editor.openModalWindow("upgradeTerrainMaterialsModal")
            end
            im.tooltip("Upgrade Terrain Materials to the new PBR pipeline.")
          else
            if im.CollapsingHeader1("Edit TerrainMaterialTextureSet Properties", im.TreeNodeFlags_DefaultOpen) then
              local obj = scenetree.findObject(editor_terrainEditor.getTerrainBlock():getField('materialTextureSet', 0))
              if obj then
                for k,v in ipairs(terrainMaterialTextureSetProperties) do
                  widgetInt2(v.property, v.name, obj, v.tooltip)
                end

                im.SetCursorPosX(im.GetContentRegionAvailWidth() - ((2 * im.GetStyle().FramePadding.x) + im.CalcTextSize("Apply Changes").x))
                if im.Button("Apply Changes") then
                  editor.logInfo("Applying changes to Terrain Material Texture Set")
                  scenetree.terrainMatEditor_PersistMan:setDirty(obj, '')
                  scenetree.terrainMatEditor_PersistMan:saveDirty()
                end
                im.tooltip("Apply changes to the Terrain Material Texture Set object.")
              end
            end
          end
        end

        if editor_terrainEditor.getErrors()['deprecated_material_file'] == true then
          im.Dummy(im.ImVec2(0,20))
          im.PushTextWrapPos(im.GetContentRegionAvailWidth())
          im.TextColored(editor.color.warning.Value, "The Terrain Materials reside in a file with a deprecated format.")
          if im.Button("Upgrade Terrain Material file format", im.ImVec2(im.GetContentRegionAvailWidth(), 0)) then
            upgradeTerrainMaterialFileFormat()
          end
          im.PopTextWrapPos()
        end
      end
      im.EndChild()
      im.NextColumn()
      -- MATERIAL PROPERTIES COLUMN
      -- local size = im.ImVec2(0, materialEditorWindowSize.y - (fontSize + 2 * editor_terrainEditor.getVars().style.FramePadding.y + editor_terrainEditor.getVars().style.WindowPadding.y) - (fontSize + editor_terrainEditor.getVars().style.WindowPadding.y + editor_terrainEditor.getVars().style.ItemSpacing.y) - (fontSize + editor_terrainEditor.getVars().style.ItemSpacing.y))
      local size = im.ImVec2(0, 0) -- fill remaining height inside ##TerrainMatEditor_MainScroll
      if im.BeginChild1("Material Properties##Child", size, true) then
        if editor_terrainEditor.getTerrainBlock() and terrainMtlCopyProxy and terrainMtlProxy then
          materialPropertiesGuiBase()
          if editor_terrainEditor.getTerrainBlock():getField('materialTextureSet', 0) == "" then
            materialPropertiesGuiV0()
          else
            materialPropertiesGuiV1()
          end

          local annotations = editor.getAnnotations()
          local annotationsTbl = editor.getAnnotationsTbl()
          local bgColor = nil
          local value = terrainMtlCopyProxy.material:getField("annotation", 0)
          if not annotationsTbl or not annotationsTbl[value] then
            bgColor = im.ImVec4(0, 0, 0, 1)
          else
            bgColor =
              im.ImVec4(
              annotationsTbl[value].r / 255,
              annotationsTbl[value].g / 255,
              annotationsTbl[value].b / 255,
              1.0)
          end
          im.TextUnformatted("Annotation:")
          im.SameLine()
          im.ColorButton("Annotation color", bgColor, 0, im.ImVec2(25, 19))
          im.SameLine()
          im.PushItemWidth(im.GetContentRegionAvailWidth())
          if im.BeginCombo("##annotation", value, im.ComboFlags_HeightLargest) then
            for n = 1, tableSize(annotations) do
              local isSelected = (value == annotations[n]) and true or false
              local bgColor = nil
              if not annotationsTbl or not annotationsTbl[annotations[n]] then
                bgColor = im.ImVec4(0, 0, 0, 1)
              else
                bgColor =
                  im.ImVec4(
                  annotationsTbl[annotations[n]].r / 255,
                  annotationsTbl[annotations[n]].g / 255,
                  annotationsTbl[annotations[n]].b / 255,
                  1.0)
              end
              im.ColorButton("annotationColorButton", bgColor, 0, im.ImVec2(25, 19))
              im.SameLine()
              if im.Selectable1(annotations[n], isSelected) then
                value = annotations[n]
                if noAnnotationString == value then
                  value = ""
                end
                terrainMtlCopyProxy.material:setField("annotation", 0, value)
              end
              if isSelected then
                -- set the initial focus when opening the combo
                im.SetItemDefaultFocus()
              end
            end
            im.EndCombo()
          end
          im.PopItemWidth()

        else
          im.TextUnformatted("No Terrain Material selected")
        end
      end
      im.EndChild()
    end
    im.Columns(1)
    im.EndChild()

    im.Separator()
    local canSave = true
    local vErrors, vWarnings = {}, {}
    if terrainMtlCopyProxy then
      local res, errs, warns = validateMaterialProxy(terrainMtlCopyProxy, { useCache = true, cacheKey = "selected" })
      vErrors, vWarnings = errs, warns
      lastValidation.errors = vErrors
      lastValidation.warnings = vWarnings
      canSave = (#vErrors == 0)
    end
    -- Compact status line
    if terrainMtlCopyProxy then
      local errCount = #vErrors
      local warnCount = #vWarnings
      if errCount > 0 then
        im.TextColored(im.ImVec4(1.0, 0.2, 0.2, 1.0), string.format("Selected Material validation: %d error(s), %d warning(s)", errCount, warnCount))
      elseif warnCount > 0 then
        im.TextColored(im.ImVec4(1.0, 0.75, 0.2, 1.0), string.format("Selected Material validation: %d warning(s)", warnCount))
      else
        im.TextColored(im.ImVec4(0.2, 1.0, 0.2, 1.0), "Selected Material validation: OK")
      end
    else
      im.TextUnformatted("No Terrain Material selected")
    end

    if im.BeginChild1("##TerrainMatEditor_ValidationScroll", im.ImVec2(0, detailsH), true) then
      if terrainMtlCopyProxy then
        drawValidationSummary(vErrors, vWarnings)
      end
    end
    im.EndChild()

    im.Dummy(im.ImVec2(0, 2 * im.uiscale[0]))

    if terrainMtlCopyProxy then
      if not canSave then im.BeginDisabled() end
      if not terrainMtlCopyProxy.isNew then
        if im.Button("Save Changes To File") then
          terrainMaterialEditor_Accept()
        end
      else
        if im.Button("Add Material") then
          terrainMaterialEditor_Accept()
        end
        im.SameLine()
        if im.Button("Cancel") then
          terrainMtlCopyProxy.material:deleteObject()
          terrainMtlCopyProxy = nil
        end
      end
      if not canSave then im.EndDisabled() end
      im.SameLine()
      if im.Button("Revalidate") then
        invalidateValidationCache()
      end
      helpTooltip("Clears cached validation results and re-runs validation.")
    end
  end
  editor.endWindow()
end

local function showTerrainMaterialsEditor(internalName)
  for id, mtl in pairs(editor_terrainEditor.getMaterialsInJson()) do
    if mtl.internalName == internalName then
      editMaterial(mtl)
    end
  end
  editor.showWindow(terrainMaterialEditorWindowName)
end

local function onEditorInitialized()
  editor.registerWindow(terrainMaterialEditorWindowName, im.ImVec2(710,530))
  editor.showTerrainMaterialsEditor = showTerrainMaterialsEditor

  editor.registerModalWindow("bulkChangeTexturesModal", im.ImVec2(200, 300))
  editor.registerModalWindow("upgradeTerrainMaterialsModal", im.ImVec2(600, 300))
  editor.registerModalWindow("upgradeTerrainMaterialsFileFormatModal", im.ImVec2(700, 340))
  editor.registerModalWindow("importTerrainMaterialsModal", im.ImVec2(400, 400))
end

local function onEditorActivated()
  -- we need to update (load) the material library so we can show the list of materials
  if editor.isWindowVisible(terrainMaterialEditorWindowName) then
    editor_terrainEditor.updateMaterialLibrary()
    invalidateValidationCache()
  end
end

-- public interface
M.dependencies = {"editor_terrainEditor"}
M.onEditorInitialized = onEditorInitialized
M.onEditorGui = onEditorGui
M.onEditorActivated = onEditorActivated

return M