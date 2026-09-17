-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local ffi = require('ffi')
local colorTempUI = require("editor/api/colorTemperatureUI")
local cubemapEditor = require('editor/cubemapEditor')

local M = {}
local logTag = 'editor_materiaEditor: '
local dbg = false

local toolWindowName = 'materialEditor'
local createMaterialWindowName = "materialEditorCreateMaterial"
local materialPreviewWindowName = "materialEditorMaterialPreview"
local materialsByTagsWindowName = "materialEditorMaterialsByTag"
local materialUsageWindowName = "materialEditorMaterialUsage"

local focusWindow = false

local im = ui_imgui
local v = {}
v.materialUsage = { lastMat = nil, rows = {}, total = 0 }

-- bit operators
local tobit, band, bor, tohex, bxor = bit.tobit, bit.band, bit.bor, bit.tohex, bit.bxor

-- copy/paste
local copiedValues = {}

-- filter
local matFilter = im.ImGuiTextFilter()
local filteredBySceneSelection = false

-- material preview
local previewMeshesPath = "/art/shapes/material_preview/"
local previewMeshes = nil
local previewMeshNamesPtr = nil
local previewMeshIndex = im.IntPtr(0)

local groundModels = nil
local tags = nil
local sortedTags = nil

local matPreview = ShapePreview()
local extMatPreview = ShapePreview()
local matPreviewBackgroundColor = ColorI(128,128,128,255)
local extMatPreviewBackgroundColor = ColorI(128,128,128,255)

local matPreviewRenderSize = 256
local extMatPreviewRenderSize = matPreviewRenderSize
-- rotation, view, sun, zoom, resetView
matPreview:setInputEnabledEx(true, false, true, false, true)
extMatPreview:setInputEnabledEx(true, false, true, true, true)
local dimRdr = RectI(0, 0, matPreviewRenderSize, matPreviewRenderSize)
local extDimRdr = RectI(0, 0, matPreviewRenderSize, matPreviewRenderSize)

local levelPath = nil
local lastPath = nil
local lastCreateMaterialPath = nil

local formerEditMode = nil

local openPickMapToFromObjectPopup = false
local pickMapToFromObjectPopupPos = nil
local pickMapToFromObjectPopupHeight = nil
local pickMapToFromObjectPopupMaxHeight = 400
local pickMaterialFromObject = false
local pickingFromObjectMaterials = nil
local pickingFromObjectMapTos = nil
local pickMaterialsFromObjectName = nil
-- Copy of material names from last "pick object from scene" (selection is cleared after pick).
local rayPickMaterialNameList = nil
local pickingFromObjectMode_enum = {
  new_material = 1,
  existing_material = 2,
  from_object_selection = 3
}
local pickingFromObjectMode = 0

local createMaterialMessage = nil
local createMaterialName = ""
local createMaterialError = false

-- serialization
v.serializationPath = "/settings/editor/materialEditor_settings.json"
v.dirtyMaterials = {}

-- options
local options = {}
-- options.thumbnailSize = 64
-- options.maxMaterialPreviewSize = 256
-- options.materialName = {}
-- options.textFilterResultsWithSameFirstCharAtTop = true

local updateMaterialPreviewRender = false

--
v.picking = false

-- imgui
v.style = nil
v.inputWidgetHeight = nil

--
local newMatName = im.ArrayChar(128)
local newMatMapTo = im.ArrayChar(128)
local newMatPath = im.ArrayChar(512)
local newMatMapToLocked = false

local editMatName = ""

-- Materials
v.materialNameList = nil
v.materialNamesPtr = nil

-- Object materials
local objectMaterialNames = nil
local objectMaterialNamesPtr = nil
local objectMaterialIndex = im.IntPtr(0)

-- Max number of layers for materials v1.5
local maxLayers = 4

-- est tex size for now
local estGFXFormatSize = {
  GFXFormatDXT1        = 2/3,
  GFXFormatDXT1_SRGB   = 2/3,
  GFXFormatBC4         = 2/3,
  GFXFormatDXT2        = 4/3,
  GFXFormatDXT3        = 4/3,
  GFXFormatDXT3_SRGB   = 4/3,
  GFXFormatDXT4        = 4/3,
  GFXFormatDXT5        = 4/3,
  GFXFormatDXT5_SRGB   = 4/3,
  GFXFormatBC5U        = 4/3,
  GFXFormat3Dc         = 4/3,
  GFXFormatBC6H_U      = 4/3,
  GFXFormatBC6H_S      = 4/3,
  GFXFormatBC7_U       = 4/3,
  GFXFormatBC7_U_SRGB  = 4/3,
  GFXFormatR8            = 1,
  GFXFormatR8G8B8        = 3,
  GFXFormatR8G8B8A8      = 4,
  GFXFormatR8G8B8X8      = 4,
  GFXFormatR8G8B8A8_SRGB = 4,
  GFXFormatR8G8B8X8_SRGB = 4,
  GFXFormatR16           = 2,
  GFXFormatR16G16B16     = 6,
  GFXFormatR16G16B16A16  = 8,
}

local function getGPUSize(texture)
  local size = 0
  if texture then
    if estGFXFormatSize[texture.format] then
      size = texture.size.x * texture.size.y * estGFXFormatSize[texture.format]
    end
  end
  return size
end

-- Texture issue checks
local texIssues = { lastMatId = nil, dirty = true, byKey = {} }

local function isPow2(n)
  if not n or n <= 0 then return false end
  return band(n, n - 1) == 0
end

local function normalizePathForCheck(mat, p)
  if not p or p == "" then return "", "" end
  local isTag = string.startswith(p, '@') or string.startswith(p, '^')
  if isTag then return p, p end
  if not string.find(p, "/", 1, true) then
    return p, (mat:getPath() .. p)
  else
    return p, p
  end
end

v.totalTexSize = { lastMatId = nil, dirty = true, size = 0 }
local function computeTotalTextureSize(mat)
  if not mat then return 0 end
  if v.totalTexSize.dirty == false and v.totalTexSize.lastMatId == mat:getId() then
    return v.totalTexSize.size
  end

  local version = tonumber(mat:getField("version", 0)) or 0
  local layers
  if version < 1.5 then
    layers = maxLayers or 4
  else
    layers = tonumber(mat.activeLayers) or 1
    if layers < 1 then layers = 1 end
    if maxLayers and layers > maxLayers then layers = maxLayers end
  end

  local total = 0
  local seen = {}
  local fields = mat:getFields() or {}
  for k, v in pairs(fields) do
    if v.type == "filename" then
      for layer = 0, layers - 1 do
        local raw = mat:getField(k, layer) or ""
        if raw ~= "" then
          local _, abs = normalizePathForCheck(mat, raw)
          local isTagged = string.startswith(raw, "@") or string.startswith(raw, "^")
          if not isTagged and abs and abs ~= "" and not seen[abs] then
            local tex = editor.getTempTextureObj(abs)
            if tex then
              total = total + (getGPUSize(tex) or 0)
              seen[abs] = true
            end
          end
        end
      end
    end
  end

  v.totalTexSize.lastMatId = mat:getId()
  v.totalTexSize.size = total
  v.totalTexSize.dirty = false
  return total
end

local function pushIssue(key, level, text)
  if not texIssues.byKey[key] then texIssues.byKey[key] = {} end
  table.insert(texIssues.byKey[key], { level = level, text = text })
end

local function scanTextureIssues(currentMaterial)
  if not currentMaterial then return end
  if texIssues.dirty == false and texIssues.lastMatId == currentMaterial:getId() then return end

  texIssues.byKey = {}
  texIssues.lastMatId = currentMaterial:getId()
  texIssues.dirty = false

  local layers = tonumber(currentMaterial.activeLayers) or 1
  if layers < 1 then layers = 1 end

  local fields = currentMaterial:getFields() or {}
  local matFile = currentMaterial:getFilename() or ""
  local isVehicleMat = (string.find(matFile, "/vehicles/", 1, true) ~= nil)
  local version = tonumber(currentMaterial:getField("version", 0)) or 0

  local optimal = {
    GFXFormatBC7_U = true,
    GFXFormatBC7_U_SRGB = true,
    GFXFormatBC4 = true,
    GFXFormatBC5U = true,
    GFXFormat3Dc = true -- alias of BC5U
  }
  local legacyCompressed = {
    GFXFormatDXT1 = true,
    GFXFormatDXT1_SRGB = true,
    GFXFormatDXT2 = true,
    GFXFormatDXT3 = true,
    GFXFormatDXT3_SRGB = true,
    GFXFormatDXT4 = true,
    GFXFormatDXT5 = true,
    GFXFormatDXT5_SRGB = true,
    GFXFormatBC6H_U = true,
    GFXFormatBC6H_S = true
  }
  local rgb = {
    detailMap = true,
    colorPaletteMap = true,
    emissiveMap = true
  }
  local grayscale = {
    metallicMap = true,
    roughnessMap = true,
    opacityMap = true,
    ambientOcclusionMap = true,
    clearCoatMap = true
  }
  local normal = {
    normalMap = true,
    detailNormalMap = true,
    clearCoatBottomNormalMap = true
  }

  for k, f in pairs(fields) do
    if f.type == "filename" then
      for layer = 0, layers - 1 do
        local raw = currentMaterial:getField(k, layer) or ""
        if raw ~= "" then
          local key = k .. ":" .. tostring(layer)
          local rel, abs = normalizePathForCheck(currentMaterial, raw)
          local lower = string.lower(rel)
          local isTagged = string.startswith(raw, "@") or string.startswith(raw, "^")
          if not isTagged and not string.find(rel, "/", 1, true) then
            pushIssue(key, 3, "Mapped texture uses relative path: " .. rel)
          end
          if not isTagged and not string.find(rel, ".", 1, true) then
            pushIssue(key, 3, "Mapped texture is missing file extension: " .. rel)
          end
          if string.find(rel, " ", 1, true) then
            pushIssue(key, 3, "Space found in texture path: " .. rel)
          end

          if isVehicleMat and not isTagged then
            if not (string.startswith(lower, "vehicles/") or string.startswith(lower, "/vehicles/")) then
              pushIssue(key, 1, "Non-vehicle texture mapped in a vehicle material: " .. rel)
            end
          end

          local isPng = string.endswith(lower, ".png")
          local isDds = string.endswith(lower, ".dds")
          local isCookerSuffix =
            string.endswith(lower, ".color.png") or
            string.endswith(lower, ".normal.png") or
            string.endswith(lower, ".data.png")

          local pngWithoutCookerSuffix = false
          local ddsWithoutCookerSuffix = false
          local ddsWithCookerSuffix = false

          if isPng then
            if not isCookerSuffix then
              pngWithoutCookerSuffix = true
            elseif not FS:fileExists(abs) then
              pushIssue(key, 1, "Texture cooker source file not found: " .. rel)
            end
          elseif isDds then
            if string.endswith(lower, ".data.dds") or string.endswith(lower, ".color.dds") or string.endswith(lower, ".normal.dds") then
              ddsWithCookerSuffix = true
            else
              ddsWithoutCookerSuffix = true
            end
          end

          if not isTagged and abs ~= "" then
            local tex = editor.getTempTextureObj(abs)
            if tex and tex.format and tex.size and tex.size.x and tex.size.y and tex.size.x == 0 and tex.size.y == 0 and tex.format == "no_format" then
              pushIssue(key, 3, "Mapped texture not found: " .. abs)
            else
              if tex and tex.size and tex.size.x and tex.size.y and tex.size.x > 0 and tex.size.y > 0 then
                if tex.size.x < 16 or tex.size.y < 16 then
                  pushIssue(key, 2, "Texture size is smaller than 16px: " .. tostring(tex.size.x) .. "x" .. tostring(tex.size.y))
                end
                if not isPow2(tex.size.x) or not isPow2(tex.size.y) then
                  pushIssue(key, 3, "Texture is not a power of 2: " .. tostring(tex.size.x) .. "x" .. tostring(tex.size.y))
                end
              end
              if tex and tex.format then
                local fmt = tex.format
                local isOptimalFormat = optimal[fmt] == true
                if pngWithoutCookerSuffix then
                  if not isOptimalFormat then
                    pushIssue(key, 3, "PNG without texture cooker suffix (.color/.normal/.data): " .. rel)
                  else
                  end
                end
                if ddsWithCookerSuffix then
                  if not isOptimalFormat then
                    pushIssue(key, 3, "Mapping uses DDS with texture-cooker suffix (not recookable): " .. rel)
                  else
                    pushIssue(key, 1, "DDS uses texture-cooker suffix, but loaded format is optimal: " .. rel)
                  end
                end
                if ddsWithoutCookerSuffix then
                  if not isOptimalFormat then
                    pushIssue(key, 2, "DDS without texture cooker suffix (.color/.normal/.data): " .. rel)
                  else
                    pushIssue(key, 1, "DDS without texture cooker suffix, but loaded format is optimal: " .. rel)
                  end
                end
                if isCookerSuffix and optimal[fmt] ~= true then
                  pushIssue(key, 3, "Found an uncooked PNG texture: " .. rel)
                end
                if legacyCompressed[fmt] and not optimal[fmt] then
                  pushIssue(key, 2, "Potentially suboptimal or outdated texture format: " .. fmt)
                end
                if not (legacyCompressed[fmt] or optimal[fmt]) then
                  pushIssue(key, 3, "Slow texture format: " .. fmt)
                end
                if version > 1 then
                  if k == "diffuseMap" and fmt ~= "GFXFormatBC7_U_SRGB" then
                    pushIssue(key, 1, "Unexpected format for diffuseMap: expected BC7 (sRGB), got " .. fmt)
                  end
                  if rgb[k] and fmt ~= "GFXFormatBC7_U" then
                    pushIssue(key, 1, "Unexpected format for " .. k .. ": expected BC7 (linear), got " .. fmt)
                  end
                  if grayscale[k] and fmt ~= "GFXFormatBC4" then
                    pushIssue(key, 2, "Unexpected/suboptimal format for " .. k .. ": expected BC4 (grayscale), got " .. fmt)
                  end
                  if normal[k] and not (fmt == "GFXFormatBC5U" or fmt == "GFXFormat3Dc") then
                    pushIssue(key, 2, "Unexpected format for " .. k .. ": expected BC5/3Dc (normal map), got " .. fmt)
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

local function hasTextureErrors()
  for _, list in pairs(texIssues.byKey or {}) do
    for _, it in ipairs(list) do
      if it.level == 3 then return true end
    end
  end
  return false
end

local function drawTextureIssueIcons(property, layer)
  layer = layer or o.layer[0]
  local key = property .. ":" .. tostring(layer)
  local list = texIssues.byKey[key]
  if not list or #list == 0 then return end

  local err, warn, info = {}, {}, {}
  for _, it in ipairs(list) do
    if it.level == 3 then
      table.insert(err, it)
    elseif it.level == 2 then
      table.insert(warn, it)
    else
      table.insert(info, it)
    end
  end

  local iconW   = v.inputWidgetHeight
  local style   = v.style
  local spacing   = style.ItemSpacing.x

  local hasErr  = (#err  > 0)
  local hasWarn = (#warn > 0)
  local hasInfo = (#info > 0)
  local num = (hasErr and 1 or 0) + (hasWarn and 1 or 0) + (hasInfo and 1 or 0)
  if num == 0 then return end

  im.SameLine()
  im.Dummy(im.ImVec2(im.GetContentRegionAvailWidth() - (num*iconW * im.uiscale[0] + num*spacing + 10),1))
  im.SameLine()

  local function popupId(suf) return "TexIssues_" .. key .. "_" .. suf end
  local titleText = { info = "Info", warn = "Warning", err = "Error" }

  local function drawOne(items, icon, tint, suf, isLast)
    if #items == 0 then return end

    local clicked = editor.uiIconImageButton(icon, im.ImVec2(iconW, iconW), tint)
    if clicked then
      im.OpenPopup(popupId(suf))
    end
    im.tooltip(tostring(#items) .. " issue(s)")

    if im.BeginPopup(popupId(suf)) then
      im.TextUnformatted(titleText[suf])
      im.Separator()
      for _, it in ipairs(items) do
        im.BulletText("%s", it.text)
      end
      im.EndPopup()
    end

    if not isLast then
      im.SameLine(0, spacing)
    end
  end

  local hasWarnIcon  = editor.icons and editor.icons.warning
  local hasErrorIcon = editor.icons and editor.icons.error
  local hasInfoIcon  = editor.icons and editor.icons.info

  local warnCol = im.ImVec4(1.00, 0.85, 0.30, 1.0)
  local errCol  = im.ImVec4(1.00, 0.25, 0.25, 1.0)
  local infoCol = im.ImVec4(0.45, 0.65, 1.00, 1.0)

  local errIcon  = hasErrorIcon
  local warnIcon = hasWarnIcon
  local infoIcon = hasInfoIcon

  local order = {}
  if #err  > 0 then table.insert(order, {"err",  err,  errIcon,  hasErrorIcon and nil or errCol}) end
  if #warn > 0 then table.insert(order, {"warn", warn, warnIcon, hasWarnIcon and nil or warnCol}) end
  if #info > 0 then table.insert(order, {"info", info, infoIcon, hasInfoIcon and nil or infoCol}) end

  for i, e in ipairs(order) do
    local suf, items, icon, tint = e[1], e[2], e[3], e[4]
    drawOne(items, icon, tint, suf, i == #order)
  end
end

local function computeMaterialUsageForMatName(matName)
  local usageByMesh = {}
  local total = 0
  local meshNames = scenetree.findClassObjects('TSStatic')
  for _, objName in ipairs(meshNames) do
    local obj = scenetree.findObject(objName)
    if obj then
      local mats = obj.getMaterialNames and obj:getMaterialNames() or nil
      if mats then
        for _, mname in ipairs(mats) do
          if mname == matName then
            local mesh = obj.getModelFile and obj:getModelFile() or obj:getField("shapeName", 0) or "(unknown mesh)"
            usageByMesh[mesh] = (usageByMesh[mesh] or 0) + 1
            total = total + 1
            break
          end
        end
      end
    end
  end
  local rows = {}
  for mesh, count in pairs(usageByMesh) do
    table.insert(rows, { mesh = mesh, count = count })
  end
  table.sort(rows, function(a,b)
    if a.count == b.count then return a.mesh < b.mesh end
    return a.count > b.count
  end)

  local forestUsageByShape = {}
  local forestTotal = 0
  local defs = scenetree.findClassObjects('ForestItemData')
  local shapeLoader = ShapePreview()
  for _, defName in ipairs(defs) do
    local defObj = scenetree.findObject(defName)
    if defObj then
      local shape = defObj:getField("shapeFile", 0)
      if shape and shape ~= "" and FS:fileExists(shape) then
        shapeLoader:setObjectModel(shape)
        local mm = shapeLoader:getMaterialNames()
        shapeLoader:clearShape()
        local usesMat = false
        if mm then
          for _, m in ipairs(mm) do
            if m == matName then
              usesMat = true
              break
            end
          end
        end
        if usesMat then
          forestUsageByShape[shape] = (forestUsageByShape[shape] or 0) + 1
          forestTotal = forestTotal + 1
        end
      end
    end
  end
  local forestRows = {}
  for mesh, count in pairs(forestUsageByShape) do
    table.insert(forestRows, { mesh = mesh, count = count })
  end
  table.sort(forestRows, function(a,b)
    if a.count == b.count then return a.mesh < b.mesh end
    return a.count > b.count
  end)

  v.materialUsage = {
    lastMat = matName,
    rows = rows,
    total = total,
    forestRows = forestRows,
    forestTotal = forestTotal
  }
end

local function resolvePath(res)
  if not res then return nil end
  local p = res
  if not string.startswith(p or '', '/') and FS:fileExists('/'..(p or '')) then
    p = '/'..p
  end
  if p then
    if FS:isLinkFile(p) then
      local link = jsonReadFile(p..'.link')
      return link.path or nil
    end
    return p
  end
end

local mu_selectedKey = nil

local function materialUsageContextMenu(res, count)
  local popupId = "MU_Popup_" .. tostring(res) .. tostring(count)
  if im.BeginPopup(popupId) then
    local _, base = path.splitWithoutExt(res or '')
    im.Text('['..((base and base ~= '') and base or tostring(res))..']')

    local suffix = "##"..tostring(res)..tostring(count)

    if im.Selectable1("Open in Explorer"..suffix) then
      local p = resolvePath(res)
      if p and FS:fileExists(p) then
        Engine.Platform.exploreFolder(p)
      else
        log('E', '', 'Path :'..tostring(p or res)..' does not exist')
      end
      im.CloseCurrentPopup()
    end

    if im.Selectable1("Preview"..suffix) then
      local p = resolvePath(res)
      if p and FS:fileExists(p) then
        if editor_shapeEditor then editor_shapeEditor.showShapeEditorLoadFile(p) end
      else
        log('E', '', 'Path :'..tostring(p or res)..' does not exist')
      end
      im.CloseCurrentPopup()
    end

    if im.Selectable1("Copy"..suffix) then
      im.SetClipboardText(tostring(res))
      im.CloseCurrentPopup()
    end

    im.EndPopup()
  end
end

local function drawRectBg(text, color, hover, smol)
  local pos = im.GetCursorScreenPos()
  local ts  = im.CalcTextSize(text)
  local x1  = pos.x - 2
  local y1  = pos.y - 1
  if hover == 1 then y1 = y1 - ts.y - 2 end
  local x2  = (smol == 1) and (x1 + ts.x + 3) or (x1 + im.GetWindowWidth())
  local y2  = y1 + ts.y + ((smol == 1) and 4 or 1)
  im.ImDrawList_AddRectFilled(im.GetWindowDrawList(), im.ImVec2(x1, y1), im.ImVec2(x2, y2), im.GetColorU322(color), 0, nil)
end

local function materialUsageWindowGui()
  if editor.beginWindow(materialUsageWindowName, "Material Usage") then
    local data = v.materialUsage
    if not data or not data.lastMat then
      im.TextUnformatted("No data. Use the button in Material Info to scan usage.")
    else
      im.TextUnformatted("Material: " .. tostring(data.lastMat))
      im.SameLine()
      if im.SmallButton("Refresh") then
        computeMaterialUsageForMatName(data.lastMat)
      end

      im.Separator()
      im.TextUnformatted(string.format(
        "TSStatic: %d    ForestItemData: %d",
        tonumber(data.total or 0) or 0,
        tonumber(data.forestTotal or 0) or 0
      ))
      im.Separator()

      local colHdr   = im.ImVec4(0.5, 0.9, 1, 1)
      local colEven  = im.ImVec4(1, 1, 1, 0.06)
      local colOdd   = im.ImVec4(0, 0, 0, 0.1)
      local colSel   = im.ImVec4(0.8, 0.4, 0.1, 1)
      local colHover = im.ImVec4(0.2, 0.24, 0.31, 0.78)

      local avail = im.GetContentRegionAvail()
      im.BeginChild1("##mu_child", im.ImVec2(avail.x, avail.y - 4*im.GetFontSize()), false, im.WindowFlags_ChildWindow + im.WindowFlags_HorizontalScrollbar)

      -- Section 1: TSStatic
      im.TextColored(colHdr, "TSStatic objects")
      im.Columns(2, "matUsageCols_ts")
      im.TextColored(colHdr, "Object")
      im.NextColumn()
      im.TextColored(colHdr, "Instances")
      im.NextColumn()
      im.Separator()
      local idx = 0
      for _, row in ipairs(data.rows or {}) do
        idx = idx + 1
        local key = tostring(row.mesh or ("ts_row_"..idx))
        local even = (idx % 2 == 0)
        local selected = (mu_selectedKey == key)
        local popupId = "MU_Popup_" .. key .. idx  -- keep original scheme
        drawRectBg(key, selected and colSel or (even and colEven or colOdd))
        materialUsageContextMenu(key, idx) -- expects the "MU_Popup_"..key..idx ID inside
        im.TextColored(selected and im.ImVec4(1, 1, 1, 1) or colHdr, key)
        if im.IsItemHovered() then
          if im.IsMouseClicked(1) then
            im.OpenPopup(popupId)
          elseif im.IsMouseClicked(0) then
            mu_selectedKey = (selected and nil or key)
          else
            drawRectBg(key, colHover, 1)
            local p = resolvePath(key)
            if p and shapeHovered then shapeHovered(p) end
          end
        end
        im.NextColumn()
        im.TextUnformatted(tostring(row.count or 0))
        im.NextColumn()
      end
      im.Columns(1)

      im.Dummy(im.ImVec2(0, im.GetStyle().ItemSpacing.y))
      im.Separator()
      im.Dummy(im.ImVec2(0, im.GetStyle().ItemSpacing.y))

      -- Section 2: ForestItemData
      im.TextColored(colHdr, "ForestItemData (by shapeFile)")
      im.Columns(2, "matUsageCols_forest")
      im.TextColored(colHdr, "Shape")
      im.NextColumn()
      im.TextColored(colHdr, "Defs")
      im.NextColumn()
      im.Separator()
      local fidx = 0
      for _, row in ipairs(data.forestRows or {}) do
        fidx = fidx + 1
        local key = tostring(row.mesh or ("forest_row_"..fidx))
        local even = (fidx % 2 == 0)
        local selected = (mu_selectedKey == key)
        local popupId = "MU_Popup_" .. key .. fidx  -- keep original scheme
        drawRectBg(key, selected and colSel or (even and colEven or colOdd))
        materialUsageContextMenu(key, fidx) -- expects the "MU_Popup_"..key..fidx ID inside
        im.TextColored(selected and im.ImVec4(1, 1, 1, 1) or colHdr, key)
        if im.IsItemHovered() then
          if im.IsMouseClicked(1) then
            im.OpenPopup(popupId)
          elseif im.IsMouseClicked(0) then
            mu_selectedKey = (selected and nil or key)
          else
            drawRectBg(key, colHover, 1)
            local p = resolvePath(key)
            if p and shapeHovered then shapeHovered(p) end
          end
        end
        im.NextColumn()
        im.TextUnformatted(tostring(row.count or 0))
        im.NextColumn()
      end
      im.Columns(1)

      im.EndChild()
    end
  end
  editor.endWindow()
end

-- cobj representing the current selected obj
local currentMaterial = nil
v.currentMaterialIndex = 0

-- ### Material Properties ###
local o = {}
o.layer = im.IntPtr(0)
o.reflectionMode = im.IntPtr(0)
--
local tempUndoValue = nil
local tempBoolPtr = im.BoolPtr(true)

local customMaterialsArray = {'Standard', 'MetalicCarPaint'}
local customMaterialsArrayPtr = im.ArrayCharPtrByTbl(customMaterialsArray)

if not scenetree.matLuaEd_PersistMan then
  local persistenceMgr = PersistenceManager()
  persistenceMgr:registerObject('matLuaEd_PersistMan')
end

local enum_animFlags = {
  scroll   = tobit(0x00000001), -- 1
  rotate   = tobit(0x00000002), -- 2
  wave     = tobit(0x00000004), -- 4
  scale    = tobit(0x00000008), -- 8
  sequence = tobit(0x00000010)  -- 16
}

local loadedAllVehicleMaterials = false

local function _openPickMapToFromObjectPopup()
  if pickingFromObjectMaterials and type(pickingFromObjectMaterials) == "table" and #pickingFromObjectMaterials > 0 then
    table.sort(pickingFromObjectMaterials)
    openPickMapToFromObjectPopup = true
  end
  if formerEditMode then
    editor.selectEditMode(formerEditMode)
    formerEditMode = nil
  end
end

local function mapTagsJob()
  -- local timer = hptimer()
  -- timer:reset()
  tags = {}
  local matNames = scenetree.findClassObjects('Material')
  local matNamesSize = #matNames
  local mat = nil
  for i=1, matNamesSize do
    local matName = matNames[i]
    mat = scenetree.findObject(matName)
    if mat and mat.___type == "class<Material>" and not mat:isAutoGenerated() then
      local addedTo = {}
      for tagId = 0, 2 do
        local tag = mat:getField("materialTag", tostring(tagId))
        if tag and tag ~= "" then
          if not tags[tag] then tags[tag] = {} end
          if not addedTo[tag] then
            table.insert(tags[tag], matName)
            addedTo[tag] = true
          end
        end
      end
    end
  end

  local sortFunc = function(a,b) return string.lower(a) < string.lower(b) end

  sortedTags = tableKeys(tags)
  table.sort(sortedTags, sortFunc)
  for tagName, materials in pairs(tags) do
    table.sort(materials, sortFunc)
  end
  -- print(string.format("%0.2f", timer:stopAndReset()))
  -- dump(tags)
end

local function updateMaterialProperties()
  if not be then return end
  if dbg then editor.logInfo(logTag .. 'Update texture maps') end

  -- simple check if material editor is present or not
  if not v.materialNameList then return end

  local materialName = v.materialNameList[v.currentMaterialIndex]
  if not materialName then return end
  currentMaterial = scenetree.findObject(materialName)
  if not currentMaterial then return end

  if matPreview and currentMaterial then
    matPreview:setMaterial(currentMaterial)
    matPreview:renderWorld(dimRdr)
  end
  if extMatPreview and currentMaterial then
    extMatPreview:setMaterial(currentMaterial)
    extMatPreview:renderWorld(extDimRdr)
  end

  o.reflectionMode[0] = (currentMaterial:getField("dynamicCubemap", 0) == "1" and 1 or currentMaterial:getField("cubemap", 0) == "" and 0 or 2)
  texIssues.dirty = true
  v.totalTexSize.dirty = true
  computeTotalTextureSize(currentMaterial)
end

local function selectMaterialByName(matName, clearFilter)
  if v.materialNameList then
    --reset filter else pick doesn't work
    if clearFilter then im.ImGuiTextFilter_Clear(matFilter) end
    for k, val in ipairs(v.materialNameList) do
      if val == matName then
        v.currentMaterialIndex = k
        updateMaterialProperties()
        local levelMaterialNames = editor.getPreference("materialEditor.general.levelMaterialNames")
        levelMaterialNames[getMissionPath()] = v.materialNameList[v.currentMaterialIndex]
        editor.setPreference("materialEditor.general.levelMaterialNames", levelMaterialNames)
        return
      end
    end
    v.currentMaterialIndex = 0
  else
    -- editor.logWarn(logTag .. "No materials to select from.")
  end
end

local function copyMaterialNameList(names)
  if not names or type(names) ~= "table" then return nil end
  local out = {}
  for i, n in ipairs(names) do
    out[i] = n
  end
  return out
end

local function getMaterials(optionalMaterialNameList)
  local sortFunc = function(a,b) return string.lower(a) < string.lower(b) end

  local currentMaterialName = nil
  local materialObjectNames = optionalMaterialNameList

  if v.materialNameList then
    currentMaterialName = v.materialNameList[v.currentMaterialIndex]
  end

  local hasSceneObjectSelection = editor.selection and editor.selection.object and #editor.selection.object > 0
  local hasSceneForestSelection = editor.selection and editor.selection.forestItem and tableSize(editor.selection.forestItem) > 0
  local useRayPickMaterialList = (optionalMaterialNameList == nil and rayPickMaterialNameList ~= nil
    and not hasSceneObjectSelection and not hasSceneForestSelection)

  filteredBySceneSelection = false

  -- List all materials of the current selected object be it a TSStatic or a ForestItem
  if nil == optionalMaterialNameList and editor.selection and options and not useRayPickMaterialList then
    -- Check if there's a single SceneObject selected.
    if editor.selection.object and #editor.selection.object > 0 then
      materialObjectNames = {}
      local tbl = {}

      for _, objName in ipairs(editor.selection.object) do
        local obj = scenetree.findObject(objName)
        if obj and (obj.___type == "class<TSStatic>" or obj.___type == "class<BeamNGVehicle>") then
          local matNames = obj:getMaterialNames()
          for _, matName in ipairs(matNames) do
            if not tbl[matName] then
              tbl[matName] = 1
            end
          end
        end
      end

      for mat, _ in pairs(tbl) do
        if mat ~= "" then
          table.insert(materialObjectNames, mat)
        end
      end

      if #materialObjectNames == 0 then
        materialObjectNames = scenetree.findClassObjects('Material')
      else
        filteredBySceneSelection = true
      end
    elseif editor.selection.forestItem and tableSize(editor.selection.forestItem) > 0 then
      materialObjectNames = {}
      local tbl = {}
      for _, forestItem in ipairs(editor.selection.forestItem) do
        local matNames = forestItem:getMaterialNames()
        for _, matName in ipairs(matNames) do
          if not tbl[matName] then
            tbl[matName] = 1
          end
        end
      end

      for mat, _ in pairs(tbl) do
        table.insert(materialObjectNames, mat)
      end

      if #materialObjectNames then
        filteredBySceneSelection = true
      end
    else -- No object is selected, list all loaded materials.
      materialObjectNames = scenetree.findClassObjects('Material')
    end

    -- Check if selection has any materials applied to it, if not get all available materials.
    if #materialObjectNames == 0 then
      materialObjectNames = scenetree.findClassObjects('Material')
    end
  elseif nil == optionalMaterialNameList then
    materialObjectNames = rayPickMaterialNameList or scenetree.findClassObjects('Material')
  end

  local sortedMaterialObjectNames = {}
  local sortedMaterialObjectNamesAtTop = {}

  local textFilterString = string.lower(ffi.string(im.TextFilter_GetInputBuf(matFilter)))

  for k, v in pairs(materialObjectNames) do
    if im.ImGuiTextFilter_PassFilter(matFilter, v) and v then
      if options and options.textFilterResultsWithSameFirstCharAtTop == true and #textFilterString > 0 and string.startswith(string.lower(v), textFilterString) then
        table.insert(sortedMaterialObjectNamesAtTop, v)
      else
        table.insert(sortedMaterialObjectNames, v)
      end
    end
  end

  if tableIsEmpty(sortedMaterialObjectNames) and tableIsEmpty(sortedMaterialObjectNamesAtTop) and #textFilterString == 0 then
    sortedMaterialObjectNames = deepcopy(materialObjectNames)
  end

  table.sort(sortedMaterialObjectNames, sortFunc)
  table.sort(sortedMaterialObjectNamesAtTop, sortFunc)

  v.materialNameList= {}

  local i = 0
  for k, val in pairs(sortedMaterialObjectNamesAtTop) do
    local mat = scenetree.findObject(val)
    if mat and mat.___type == "class<Material>" then
      if not mat:isAutoGenerated() then
        v.materialNameList[i] = val
        i = i + 1
      end
    end
  end
  for k, val in pairs(sortedMaterialObjectNames) do
    local mat = scenetree.findObject(val)
    if mat and mat.___type == "class<Material>" then
      if not mat:isAutoGenerated() then
        v.materialNameList[i] = val
        i = i + 1
      end
    end
  end

  v.materialListIsNothingFound = (i == 0 and #textFilterString > 0)
  if v.materialListIsNothingFound then
    v.materialNameList[0] = "No material found by filter"
  end

  v.materialNamesPtr = im.ArrayCharPtrByTbl(v.materialNameList)
  v.materialNamesPtrCount = i

  if editor and editor.getPreference then
    local levelMaterialNames = editor.getPreference("materialEditor.general.levelMaterialNames")
    if levelMaterialNames[getMissionPath()] and levelMaterialNames[getMissionPath()] ~= "" then
      selectMaterialByName(levelMaterialNames[getMissionPath()])
    end
    updateMaterialProperties()
  end
end

local function getPickMaterialEditMode()
  return {
    onActivate = function() end,
    onDeactivate = function()
      pickMaterialFromObject = false
      worldEditorCppApi.setHoveredObjectId(0)
    end,
    onUpdate = function()
      if pickMaterialFromObject == true then
        local res = getCameraMouseRay()

        if not im.GetIO().WantCaptureMouse and editor.isViewportHovered() and not editor.isAxisGizmoHovered() then
          if core_forest.getForestObject() and not worldEditorCppApi.getClassIsSelectable("Forest") then core_forest.getForestObject():disableCollision() end
          local defaultFlags = bit.bor(SOTTerrain, SOTWater, SOTStaticShape, SOTPlayer, SOTItem, SOTVehicle, SOTForest)
          if not worldEditorCppApi.getClassIsSelectable("TSStatic") then
            defaultFlags = bit.band(defaultFlags, bit.bnot(SOTStaticShape))
          end
          local rayCastInfo = cameraMouseRayCast(true, defaultFlags)
          if core_forest.getForestObject() then core_forest.getForestObject():enableCollision() end

          if rayCastInfo then
            local hoveredId = 0

            if rayCastInfo.object then
              hoveredId = rayCastInfo.object:getID()

              if rayCastInfo.object.___type == "class<Forest>" or not rayCastInfo.object.getTransform then
                hoveredId = 0
                if editor.drawSelectedObjectBBox and rayCastInfo.object.getTransform then
                  editor.drawSelectedObjectBBox(rayCastInfo.object, ColorF(1, 0, 0, 1))
                end
              end
            end

            worldEditorCppApi.setHoveredObjectId(hoveredId)

            if im.IsMouseReleased(0) then
              if rayCastInfo.object.___type == "class<TSStatic>" then
                pickingFromObjectMaterials = rayCastInfo.object:getMeshMaterialNames()
                if pickingFromObjectMode ~= pickingFromObjectMode_enum.from_object_selection then
                  _openPickMapToFromObjectPopup()
                else
                  editor.selectObjectById(rayCastInfo.object:getID())
                  pickMaterialsFromObjectName = rayCastInfo.object:getGeneratedDisplayName()
                  rayPickMaterialNameList = copyMaterialNameList(pickingFromObjectMaterials)
                  getMaterials()
                  pickingFromObjectMaterials = nil
                  pickMaterialFromObject = false
                  pickingFromObjectMode = nil
                  editor.clearObjectSelection()
                  worldEditorCppApi.setHoveredObjectId(0)
                  if formerEditMode then
                    editor.selectEditMode(formerEditMode)
                    formerEditMode = nil
                  end
                  if editor_forestEditor then
                    editor_forestEditor.clearForestItemsSelection()
                  end
                end
              elseif rayCastInfo.object.___type == "class<Forest>" then
                local rayForest = getCameraMouseRay()
                local forestItem = rayCastInfo.object:castRayRendered(rayForest.pos, rayForest.pos + rayForest.dir * 1000).forestItem

                if forestItem then
                  pickingFromObjectMaterials = forestItem:getMaterialNames()
                  if pickingFromObjectMode ~= pickingFromObjectMode_enum.from_object_selection then
                    _openPickMapToFromObjectPopup()
                  else
                    pickMaterialsFromObjectName = rayCastInfo.object:getGeneratedDisplayName() .. ":" .. forestItem:getData():getShapeFile()
                    rayPickMaterialNameList = copyMaterialNameList(pickingFromObjectMaterials)
                    getMaterials(pickingFromObjectMaterials)
                    pickingFromObjectMaterials = nil
                    pickMaterialFromObject = false
                    pickingFromObjectMode = nil
                    editor.clearObjectSelection()
                    worldEditorCppApi.setHoveredObjectId(0)
                    if formerEditMode then
                      editor.selectEditMode(formerEditMode)
                      formerEditMode = nil
                    end
                    if editor_forestEditor then
                      editor_forestEditor.clearForestItemsSelection()
                    end
                  end
                end
              elseif rayCastInfo.object.___type == "class<BeamNGVehicle>" then
                pickingFromObjectMaterials = rayCastInfo.object:getMaterialNames()
                if pickingFromObjectMode ~= pickingFromObjectMode_enum.from_object_selection then
                  _openPickMapToFromObjectPopup()
                else
                  pickMaterialsFromObjectName = rayCastInfo.object:getGeneratedDisplayName()
                  rayPickMaterialNameList = copyMaterialNameList(pickingFromObjectMaterials)
                  getMaterials(pickingFromObjectMaterials)
                  pickingFromObjectMaterials = nil
                  pickMaterialFromObject = false
                  pickingFromObjectMode = nil
                  editor.clearObjectSelection()
                  worldEditorCppApi.setHoveredObjectId(0)
                  if formerEditMode then
                    editor.selectEditMode(formerEditMode)
                    formerEditMode = nil
                  end
                  if editor_forestEditor then
                    editor_forestEditor.clearForestItemsSelection()
                  end
                end
              end
            elseif im.IsKeyReleased(im.GetKeyIndex(im.Key_Escape)) then
              -- Cancel mapTo picking.
              pickingFromObjectMaterials = nil
              pickMaterialFromObject = false
              pickingFromObjectMode = nil
              editor.clearObjectSelection()
              worldEditorCppApi.setHoveredObjectId(0)
              if formerEditMode then
                editor.selectEditMode(formerEditMode)
                formerEditMode = nil
              end
            end
          end
        end
      end
    end,
    onDeselect = function() end,
  }
end

local function setMaterialDirty(materialObj)
  local mat = (materialObj or currentMaterial)
  if not v.dirtyMaterials[mat:getField("name", 0)] then
    v.dirtyMaterials[mat:getField("name", 0)] = true
  end
end

local function setProperty(materialObj, property, layer, value)
  local matObj = (materialObj or currentMaterial)
  if not tempUndoValue then
    tempUndoValue = matObj:getField(property, layer)
  end
  if editor.setMaterialProperty(matObj, property, layer, value) then
    setMaterialDirty(matObj)
    v.totalTexSize.dirty = true
    if editor.isWindowVisible(materialPreviewWindowName) == true then
      if extMatPreview then
        extMatPreview:renderWorld(extDimRdr)
      end
    else
      if matPreview then
        matPreview:renderWorld(dimRdr)
      end
    end
  end
end

local function propertyUndo(actionData)
  local obj = scenetree.findObjectById(actionData.objectId)
  if obj then
    setProperty(obj, actionData.property, actionData.layer, actionData.oldValue)
  end
  if o.layer[0] ~= actionData.layer then
    o.layer[0] = actionData.layer
  end
  tempUndoValue = nil
  texIssues.dirty = true
end

local function propertyRedo(actionData)
  local obj = scenetree.findObjectById(actionData.objectId)
  if obj then
    setProperty(obj, actionData.property, actionData.layer, actionData.newValue)
  end
  tempUndoValue = nil
  texIssues.dirty = true
end

local function setPropertyWithUndo(property, layer, value)
  editor.history:commitAction(
    "SetMaterialProperty_" .. property .. "_layer" .. tostring(layer),
    {
      objectId = currentMaterial:getId(),
      property =  property,
      layer = layer,
      newValue = value,
      oldValue = tempUndoValue or currentMaterial:getField(property, layer)
    },
    propertyUndo,
    propertyRedo
  )
  tempUndoValue = nil
  texIssues.dirty = true
end

local function dragDropTarget(property, layer)
  if im.BeginDragDropTarget() then
    local payload = im.AcceptDragDropPayload("ASSETDRAGDROP")
    if payload~=nil then
      assert(payload.DataSize == 2048)
      local data = ffi.string(payload.Data)
      -- editor.logInfo(logTag .. "Setting property '" .. property .. "' on layer '" .. tostring(layer or o.layer[0]) .. "' to .. '" .. data .. "'")
      setPropertyWithUndo(property, layer or o.layer[0], data)
    end
    im.EndDragDropTarget()
  end
end

local function saveCurrentMaterial()
  scenetree.matLuaEd_PersistMan:setDirty(currentMaterial, '')
  scenetree.matLuaEd_PersistMan:saveDirty()
  v.dirtyMaterials[currentMaterial:getField("name", 0)] = nil
  editor.logInfo(logTag .. "Material '" .. currentMaterial:getName() .. "' has been saved.")
  editor.showNotification("Material '" .. currentMaterial:getName() .. "' has been saved.")

  core_jobsystem.create(mapTagsJob, 1)
end

local function saveAllDirtyMaterials()
  for matName, _ in pairs(v.dirtyMaterials) do
    local mat = scenetree.findObject(matName)
    if mat then
      scenetree.matLuaEd_PersistMan:setDirty(mat, '')
    end
    v.dirtyMaterials[matName] = nil
  end
  scenetree.matLuaEd_PersistMan:saveDirty()
  editor.logInfo(logTag .. 'All dirty materials have been saved.')
  editor.showNotification("All dirty materials have been saved.")

  core_jobsystem.create(mapTagsJob, 1)
end

local function updateExtMaterialPreviewMesh()
  if #previewMeshes == 0 then return end
  extMatPreview:setObjectModel(previewMeshes[previewMeshIndex[0] + 1].path)
  extMatPreview:setMaterial(currentMaterial)
  extMatPreview:setRenderState(false,false,false,false,false,false)
  extMatPreview:setCamRotation(0.6, 3.9)
  extMatPreview:fitToShape()
  extMatPreview:renderWorld(extDimRdr)
end

local function getPreviewMeshes()
  previewMeshes = FS:findFiles(previewMeshesPath, "*.dae", -1, true, false)
  local previewMeshNames = {}
  for index, filePath in ipairs(previewMeshes) do
    local _, file, _ = path.splitWithoutExt(filePath)
    previewMeshes[index] = {path = filePath, name = file}
    table.insert(previewMeshNames, file)
  end
  previewMeshNamesPtr = im.ArrayCharPtrByTbl(previewMeshNames)
  previewMeshIndex[0] = 0
  updateExtMaterialPreviewMesh()
end

local function getGroundmodels()
  local sortFunc = function(a,b) return string.lower(a) < string.lower(b) end
  groundModels = tableKeys(core_environment.groundModels) ---
  table.sort(groundModels, sortFunc)
end

local function getOrSetMaterialFieldIntoTable(get, fieldName, layerIndex, tbl)
  if currentMaterial then
    if get then
      tbl[fieldName] = currentMaterial:getField(fieldName, layerIndex)
    else
      currentMaterial:setField(fieldName, layerIndex, tbl[fieldName])
    end
  end
end

local function getOrSetLayerData(data, get, layerIndex)
  getOrSetMaterialFieldIntoTable(get, "diffuseColor", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "instanceDiffuse", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "instanceEmissive", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "instanceOpacity", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "diffuseMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "paletteBaseColor", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "paletteMetallic", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "paletteRoughness", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "paletteClearCoat", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "paletteClearCoatRoughness", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "diffuseMapUseUV", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "overlayMapUseUV", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "detailMapUseUV", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "normalMapUseUV", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "normalDetailMapUseUV", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "opacityMapUseUV", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "colorPaletteMapUseUV", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "specularMapUseUV", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "reflectivityMapUseUV", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "roughnessMapUseUV", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "metallicMapUseUV", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "clearCoatMapUseUV", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "ambientOcclusionMapUseUV", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "emissiveMapUseUV", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "colorMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "normalMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "normalMapStrength", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "detailBaseColorMapStrength", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "roughnessFactor", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "specularPower", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "baseColorMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "baseColorFactor", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "opacityFactor", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "metallicMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "metallicFactor", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "metallicDetailMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "detailMetallicMapStrength", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "roughnessMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "roughnessDetailMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "detailRoughnessMapStrength", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "ambientOcclusionMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "ambientOcclusionDetailMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "detailAoMapStrength", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "emissiveFactor", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "emissiveIntensityNits", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "emissiveMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "retroreflectivity", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "retroreflectiveColor", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "clearCoatMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "clearCoatFactor", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "clearCoatRoughnessFactor", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "clearCoatBottomNormalMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "clearCoatBottomNormalMapStrength", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "specularityMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "clearCoatRoughnessMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "overlayMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "opacityMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "opacityMapUseUV", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "opacityDetailMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "detailOpacityMapStrength", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "opacityDetailMapUseUV", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "colorPaletteMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "lightMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "detailMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "detailScale", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "detailNormalMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "detailNormalMapStrength", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "specularMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "envMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "reflectivityMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "reflectivityMapFactor", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "specular", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "pixelSpecular", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "annotationMap", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "parallaxScale", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "useAnisotropic", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "useAnisotropicFilter", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "vertLit", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "vertColor", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "vertColorEmissive", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "minnaertConstant", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "subSurface", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "subSurfaceIntensity", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "glow", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "glowFactor", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "emissive", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "animFlags", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "scrollDir", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "scrollSpeed", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "rotSpeed", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "rotPivotOffset", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "waveType", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "waveFreq", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "waveAmp", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "sequenceFramePerSec", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "sequenceSegmentSize", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "baseTex", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "detailTex", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "overlayTex", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "bumpTex", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "envTex", layerIndex, data)
  getOrSetMaterialFieldIntoTable(get, "colorMultiply", layerIndex, data)
end

local function getLayerData(layerIndex, data)
  getOrSetLayerData(data, true, layerIndex)
end

local function setLayerData(layerIndex, data)
  getOrSetLayerData(data, false, layerIndex)
end

local function swapLayers(layer1, layer2)
  local layerData1 = {}
  local layerData2 = {}
  getLayerData(layer1, layerData1)
  getLayerData(layer2, layerData2)
  setLayerData(layer1, layerData2)
  setLayerData(layer2, layerData1)
  currentMaterial:reload()
end

local function swapLayersUndo(actionData)
  swapLayers(actionData.layer1, actionData.layer2)
end

local function swapLayersRedo(actionData)
  -- same as undo, we just toggle
  swapLayers(actionData.layer1, actionData.layer2)
end

local function swapLayersWithUndo(layer1, layer2)
  editor.history:commitAction(
    "SwapMaterialLayers",
    {
      matId = currentMaterial:getId(),
      layer1 = layer1,
      layer2 = layer2,
      timestamp = os.time() -- always need some diff value to differentiate undo actions since consecutive ones can have same params and it wont be taken into account by the history system
    },
    swapLayersUndo,
    swapLayersRedo
  )
end

local function isMapHovered(tex, path, absPath)
  if im.IsItemHovered() then
    if #absPath > 0 then
      im.BeginTooltip()
      im.PushTextWrapPos(im.GetFontSize() * 35.0)
      local size = getGPUSize(tex)
      if path ~= absPath then im.TextUnformatted(path) end
      im.TextUnformatted(absPath)
      im.TextUnformatted(string.format("Dimensions (loaded MIP): %d x %d\nFormat: %s", tex.size.x, tex.size.y, tex.format))
      im.TextUnformatted(string.format("Size (estimated): %.2f MB", size / 1e6))
      im.PopTextWrapPos()
      im.EndTooltip()
    end
  end
end

local function deleteMapButton(label, property, layer)
  local layer = layer or o.layer[0]
  im.PushID1(property .. layer .. '_RemoveMapButton')
  if editor.uiIconImageButton(
    editor.icons.material_texturemap_remove,
    im.ImVec2(v.inputWidgetHeight, v.inputWidgetHeight)
  ) then
    setPropertyWithUndo(property, layer, "")
  end
  im.tooltip("Remove " .. label)
  im.PopID()
end

-- Widgets
local function inputText(label, property, layer, setOnEditEndedOnly, widthMod, onEditEndedCallback)
  layer = layer or o.layer[0]
  tempBoolPtr[0] = false

  if label then
    im.TextUnformatted(label)
    im.SameLine()
  end
  im.PushItemWidth(im.GetContentRegionAvailWidth() + (widthMod or 0))
  if editor.uiInputText(
    "##" .. property .. tostring(layer),
    editor.getTempCharPtr(currentMaterial:getField(property, layer)),
    nil,
    im.InputTextFlags_AutoSelectAll,
    nil,
    nil,
    tempBoolPtr
  ) then
    if not setOnEditEndedOnly or setOnEditEndedOnly == false then
      setProperty(nil, property, layer, editor.getTempCharPtr())
    end
  end
  im.PopItemWidth()

  if tempBoolPtr[0] == true then
    setPropertyWithUndo(property, layer, editor.getTempCharPtr())
    if onEditEndedCallback and type(onEditEndedCallback) == "function" then
      onEditEndedCallback()
    end
  end
end

local function imageButton(label, property, layer, additionalGuiFn)
  layer = layer or o.layer[0]
  local imgPath = currentMaterial:getField(property, layer)
  local absPath = imgPath
  local isTaggedTexture = string.startswith(imgPath, '@')
  local isLevelRelativeTexture = string.startswith(imgPath, '^')

  -- Check if path is absolute or relative (exclude tagged textures)
  if absPath ~= "" and not isTaggedTexture and not isLevelRelativeTexture then
    absPath = (string.find(absPath, "/") ~= nil and absPath or (currentMaterial:getPath() .. absPath))
    if absPath ~= imgPath then
      editor.logInfo(logTag .. string.format([[
Changed texture path from '%s' to '%s' for material '%s'!
Texture paths should not rely on the path of the material file. This feature will be deprecated soon.
Hit the "Save material" button to save the changes to the material.]],
        imgPath, absPath, currentMaterial:getName())
      )
      setProperty(nil, property, layer, absPath)
    end
  end

  local function openFileDialog()
    editor_fileDialog.openFile(
      function(data)
        if absPath ~= data.filepath then
          setPropertyWithUndo(property, layer, data.filepath)
        end
        lastPath = data.path
      end,
      {{"Any files", "*"},{"Images",{".png", ".dds", ".jpg"}},{"DDS",".dds"},{"PNG",".png"},{"Color maps",".color.png"}, {"Normal maps",".normal.png"}, {"Data maps",".data.png"}},
      false,
      -- Open up lastPath dir in case there's no texture path set
      -- (absPath == "" and lastPath or path.splitWithoutExt(absPath)),
      -- Open up material's dir in case there's no texture path set
      (absPath == "" and (path.splitWithoutExt(currentMaterial:getFilename()) or lastPath) or path.splitWithoutExt(absPath)),
      true
    )
  end

  im.PushID1(property .. tostring(layer) .. "_imageButton")
  im.TextUnformatted((label or property))
  drawTextureIssueIcons(property, layer)

  inputText("Path", property, layer, true, -(3*v.inputWidgetHeight * im.uiscale[0] + 3*v.style.ItemSpacing.x + 10))
  im.SameLine()
  if editor.uiIconImageButton(
    editor.icons.folder,
    im.ImVec2(v.inputWidgetHeight, v.inputWidgetHeight)
  ) then
    openFileDialog()
  end
  im.tooltip("Open file dialog")
  im.SameLine()
  deleteMapButton(label, property, layer)
  im.SameLine()
  if editor.uiIconImageButton(
    editor.icons.open_in_new,
    im.ImVec2(v.inputWidgetHeight, v.inputWidgetHeight)
  ) then
    local p = resolvePath(absPath)
    if p and p ~= "" and FS:fileExists(p) then Engine.Platform.exploreFolder(p) else log('E', '', 'Path :'..p..' does not exist' ) end
  end
  im.tooltip("Open in explorer")

  local texture = editor.getTempTextureObj(absPath)
  local size = im.ImVec2(options.thumbnailSize, options.thumbnailSize)
  if texture and texture.size.x ~= 0 and texture.size.y ~= 0 then
    local x = options.thumbnailSize * texture.size.x / texture.size.y
    local y = options.thumbnailSize
    local mul = 1
    if x > im.GetContentRegionAvailWidth() then
      mul = im.GetContentRegionAvailWidth()/x
    end
    size.x = x * mul
    size.y = y * mul
  end

  if additionalGuiFn then
    im.Columns(2, property .. tostring(layer))
    im.SetColumnWidth(0, size.x + v.style.WindowPadding.x)
    im.SetCursorPosX(im.GetCursorPosX() - v.style.ItemSpacing.x)
  end

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
  dragDropTarget(property, layer)
  isMapHovered(editor.getTempTextureObj(), imgPath, absPath)

  if additionalGuiFn then
    im.NextColumn()
    if im.GetContentRegionAvailWidth() > 160 then
      additionalGuiFn()
      im.Columns(1)
    else
      im.Columns(1)
      additionalGuiFn()
    end
  end
  im.PopID()
end

local function fileWidget(label, property, layer, fileTypes, columnsId)
  layer = layer or o.layer[0]
  im.PushID1(property .. tostring(layer) .. "_fileWidget")
  if columnsId then im.Columns(2, columnsId) end
  im.TextUnformatted((label or property))
  if columnsId then im.NextColumn() end

  local function openFileDialog()
    editor_fileDialog.openFile(
      function(data)
        if currentMaterial:getField(property, layer) ~= data.filepath then
          setPropertyWithUndo(property, layer, data.filepath)
        end
        lastPath = data.path
      end,
      fileTypes,
      false,
      lastPath,
      true
    )
  end

  inputText(nil, property, layer, true, -(2*v.inputWidgetHeight * im.uiscale[0] + 2*v.style.ItemSpacing.x  + 10))
  im.SameLine()
  if editor.uiIconImageButton(
    editor.icons.folder,
    im.ImVec2(v.inputWidgetHeight, v.inputWidgetHeight)
  ) then
    openFileDialog()
  end
  im.tooltip("Open file dialog")
  im.SameLine()
  deleteMapButton(label, property, layer)

  if columnsId then
    im.NextColumn()
    im.Columns(1)
  end
  im.PopID()
end

local function colorEdit4(label, property, id, layer, labelSameLine)
  layer = layer or o.layer[0]
  if label and #label > 0 then
    im.TextUnformatted(label)
    if labelSameLine then im.SameLine() end
  end
  -- im.SameLine()
  tempBoolPtr[0] = false
  im.PushItemWidth(im.GetContentRegionAvailWidth() - 10)
  if editor.uiColorEdit4(
    "##rgb_" .. (id or property) .. tostring(layer),
    editor.getTempFloatArray4_StringString(currentMaterial:getField(property, layer)),
    im.flags(im.ColorEditFlags_AlphaPreviewHalf, im.ColorEditFlags_AlphaBar, im.ColorEditFlags_HDR),
    tempBoolPtr
  ) then
    setProperty(nil, property, layer, editor.getTempFloatArray4_StringString())
  end

  -- Additional HSV input fields.
  -- tempBoolPtr[0] = false
  -- if editor.uiColorEdit4(
  --   "##hsv" .. (id or property),
  --   editor.getTempFloatArray4_StringString(currentMaterial:getField(property, layer)),
  --   im.flags(im.ColorEditFlags_NoSmallPreview, im.ColorEditFlags_HSV, im.ColorEditFlags_HDR, im.ColorEditFlags_NoAlpha),
  --   tempBoolPtr
  -- ) then
  --   setProperty(nil, property, layer, editor.getTempFloatArray4_StringString())
  -- end

  if tempBoolPtr[0] == true then
    setPropertyWithUndo(property, layer, editor.getTempFloatArray4_StringString())
    tempBoolPtr[0] = false
  end
  im.PopItemWidth()
end

local function sliderInt(label, property, min, max, string_format, layer)
  layer = layer or o.layer[0]
  tempBoolPtr[0] = false
  im.TextUnformatted(label)
  im.SameLine()
  im.PushItemWidth(im.GetContentRegionAvailWidth() - 10)
  if editor.uiSliderInt(
    "##" .. property .. tostring(layer),
    editor.getTempInt_StringString(currentMaterial:getField(property, layer)),
    min or 0,
    max or 1,
    string_format or "%d",
    tempBoolPtr
  ) then
    setProperty(nil, property, layer, editor.getTempInt_StringString())
  end

  if tempBoolPtr[0] == true then
    setPropertyWithUndo(property, layer, editor.getTempInt_StringString())
    tempBoolPtr[0] = false
  end
  im.PopItemWidth()
end

local function sliderFloat(label, property, min, max, string_format, layer)
  layer = layer or o.layer[0]
  tempBoolPtr[0] = false
  im.TextUnformatted(label)
  im.SameLine()
  im.PushItemWidth(im.GetContentRegionAvailWidth() - 10)
  if editor.uiSliderFloat(
    "##" .. property .. tostring(layer),
    editor.getTempFloat_StringString(currentMaterial:getField(property, layer)),
    min or 0,
    max or 1,
    string_format or "%.3f",
    nil,
    tempBoolPtr
  ) then
    setProperty(nil, property, layer, editor.getTempFloat_StringString())
  end

  if tempBoolPtr[0] == true then
    setPropertyWithUndo(property, layer, editor.getTempFloat_StringString())
    tempBoolPtr[0] = false
  end
  im.PopItemWidth()
end

local function checkbox(label, property, layer, tooltip)
  layer = layer or o.layer[0]
  im.TextUnformatted(label)
  if tooltip then
    im.ShowHelpMarker(tooltip, true)
  end
  im.SameLine()
  if im.Checkbox(
    "##" .. property .. tostring(layer),
    editor.getTempBool_StringString(currentMaterial:getField(property, layer))
  ) then
    setPropertyWithUndo(property, layer, editor.getTempBool_StringString())
  end
end

local function checkboxFlag(label, property, hex, layer)
  layer = layer or o.layer[0]
  local animFlags = tobit(currentMaterial:getField(property, layer))
  im.TextUnformatted(label)
  im.SameLine()
  if im.Checkbox(
    "##" .. label .. property .. tostring(layer),
    editor.getTempBool_StringString((band(animFlags, hex) == hex))
  ) then
    setPropertyWithUndo(property, layer, "0x" .. tohex(bxor(animFlags, hex)))
  end
end

local function radio(label, labelValue, property, value, layer)
  layer = layer or o.layer[0]
  if im.RadioButton1(labelValue .. "##" .. label .. tostring(layer), (currentMaterial:getField(property, layer) == value)) then
    setPropertyWithUndo(property, layer, value)
  end
end

local function inputFloat(label, property, float_step, float_step_fast, string_format, layer, tooltip)
  layer = layer or o.layer[0]
  tempBoolPtr[0] = false
  im.TextUnformatted(label)
  if tooltip then
    im.ShowHelpMarker(tooltip, true)
  end
  im.SameLine()
  im.PushItemWidth(im.GetContentRegionAvailWidth() - 10)
  if editor.uiInputFloat(
    "##" .. property .. tostring(layer),
    editor.getTempFloat_StringString(currentMaterial:getField(property, layer)),
    float_step or 0.01,
    float_step_fast or 0.1,
    string_format or "%.2f",
    nil,
    tempBoolPtr
  ) then
    setProperty(nil, property, layer, editor.getTempFloat_StringString())
  end

  if tempBoolPtr[0] == true then
    setPropertyWithUndo(property, layer, editor.getTempFloat_StringString())
    tempBoolPtr[0] = false
  end
  im.PopItemWidth()
end

local function inputFloat2(label, property, string_format, layer)
  layer = layer or o.layer[0]
  tempBoolPtr[0] = false
  im.TextUnformatted(label)
  im.SameLine()
  im.PushItemWidth(im.GetContentRegionAvailWidth() - 10)
  if editor.uiInputFloat2(
    "##" .. property .. tostring(layer),
    editor.getTempFloatArray2_StringString(currentMaterial:getField(property, layer)),
    string_format or "%.2f",
    nil,
    tempBoolPtr
  ) then
    setProperty(nil, property, layer, editor.getTempFloatArray2_StringString())
  end

  if tempBoolPtr[0] == true then
    setPropertyWithUndo(property, layer, editor.getTempFloatArray2_StringString())
    tempBoolPtr[0] = false
  end
  im.PopItemWidth()
end

local function sliderFloat2(label, labelA, labelB, property, min, max, string_format, layer)
  layer = layer or o.layer[0]
  if label then im.TextUnformatted(label) end
  im.TextUnformatted(labelA)
  local fltArr2 = editor.getTempFloatArray2_StringString(currentMaterial:getField(property, layer))
  local valueA = editor.getTempFloat_StringString(fltArr2[0])
  im.SameLine()
  im.PushItemWidth(im.GetContentRegionAvailWidth() - 10)
  tempBoolPtr[0] = false
  if editor.uiSliderFloat(
    "##" .. property .. labelA .. tostring(layer),
    valueA,
    min or 0,
    max or 1,
    string_format or "%.3f",
    nil,
    tempBoolPtr
  ) then
    fltArr2[0] = valueA[0]
    setProperty(nil, property, layer, editor.getTempFloatArray2_StringString())
  end

  if tempBoolPtr[0] == true then
    setPropertyWithUndo(property, layer, editor.getTempFloatArray2_StringString())
    tempBoolPtr[0] = false
  end
  im.PopItemWidth()

  local valueB = editor.getTempFloat_StringString(fltArr2[1])
  im.TextUnformatted(labelB)
  im.SameLine()
  im.PushItemWidth(im.GetContentRegionAvailWidth() - 10)
  tempBoolPtr[0] = false
  if editor.uiSliderFloat(
    "##" .. property .. labelB .. tostring(layer),
    valueB,
    min or 0,
    max or 1,
    string_format or "%.3f",
    nil,
    tempBoolPtr
  ) then
    fltArr2[1] = valueB[0]
    setProperty(nil, property, layer, editor.getTempFloatArray2_StringString())
  end

  if tempBoolPtr[0] == true then
    setPropertyWithUndo(property, layer, editor.getTempFloatArray2_StringString())
    tempBoolPtr[0] = false
  end
  im.PopItemWidth()
end

local function combo(label, property, items, layer, columnsId)
  layer = layer or o.layer[0]
  local index = -1
  local field = currentMaterial:getField(property, layer)
  for k, v in pairs(items) do
    if v == field then
      index = (k - 1)
      break
    end
  end
  local cptr = im.ArrayCharPtrByTbl(items)
  if columnsId then
    im.Columns(2, columnsId .. "##combo" .. label .. property .. tostring(layer))
    im.SetColumnWidth(0, 110)
  end
  im.TextUnformatted(label)
  if columnsId then
    im.NextColumn()
  else
    im.SameLine()
  end
  im.PushItemWidth(im.GetContentRegionAvailWidth() - 10)
  if im.Combo1("##" .. label .. property .. tostring(layer), editor.getTempInt_StringString(index), cptr) then
    setPropertyWithUndo(property, layer, items[tonumber(editor.getTempInt_StringString()) + 1])
  end
  im.PopItemWidth()
  if columnsId then im.Columns(1) end
end

local function text(property, layer)
  im.TextUnformatted(currentMaterial:getField(property, layer or o.layer[0]))
end
-- ~Widgets

local function setMaterialPropertiesColumnWidth()
  -- Each "Material Properties" columns block now uses a unique columns id to avoid ImGui id
  -- conflicts (multiple blocks sharing one columns id produced conflicting column-separator
  -- items). Because the width can no longer be shared through a single columns id, it is set
  -- explicitly here for every block.
  im.SetColumnWidth(0, 110)
end

local function cubemap()
  im.Columns(2, "Material Properties##cubemap")
  setMaterialPropertiesColumnWidth()
  im.TextUnformatted("Reflection Mode")
  im.NextColumn()
  im.PushItemWidth(120)
  local currentReflectionMode = o.reflectionMode[0]
  if im.Combo2("##reflectionMode", o.reflectionMode, "None\0Level\0Cubemap\0\0") then
    if o.reflectionMode[0] == 0 and currentReflectionMode ~= 0 then
      setProperty(nil, "cubemap", 0, "")
      setProperty(nil, "dynamicCubemap", 0, "0")
    elseif o.reflectionMode[0] == 1 and currentReflectionMode ~= 1 then
      setProperty(nil, "cubemap", 0, "")
      setProperty(nil, "dynamicCubemap", 0, "1")
    elseif o.reflectionMode[0] == 2 and currentReflectionMode ~= 2 then
      setProperty(nil, "cubemap", 0, "")
      setProperty(nil, "dynamicCubemap", 0, "0")
    end
  end
  im.PopItemWidth()
  im.tooltip("None = Material doesn't use any reflection information\nLevel = Material uses reflection information from the level\nCubemap = Material uses reflection information from a custom cubemap")

  if o.reflectionMode[0] == 1 then

    im.SameLine()
    if im.Button("Edit") then
      cubemapEditor.show()
    end
  elseif o.reflectionMode[0] == 2 then
    im.SameLine()
    local cubemapName = currentMaterial:getField("cubemap", 0)
    if im.Button("Choose") then
      cubemapEditor.show(function(chosenCubemapName)
        if chosenCubemapName and chosenCubemapName ~= "" then
          setPropertyWithUndo("cubemap", 0, chosenCubemapName)
          -- ensure reflection mode is set correctly too if you want:
          setProperty(nil, "dynamicCubemap", 0, "0")
          o.reflectionMode[0] = 2
        end
      end)
    end
    im.NextColumn()
    im.TextUnformatted("Cubemap")
    im.NextColumn()
    im.TextUnformatted(cubemapName == "" and "none" or cubemapName)
    if cubemapName == "" then
      im.TextColored(editor.color.warning.Value, "Please choose a cubemap.\nReflection won't work without a cubemap.")
    end
  end
  im.Columns(1)
end
-- ~Cubemap

-- old material editor
local function layer()
  im.PushItemWidth(im.GetContentRegionAvailWidth() - 10)
  if im.Combo2("##MaterialEditorLayer", o.layer, "Layer 0\0Layer 1\0Layer 2\0Layer 3\0\0") then
    if dbg then editor.logInfo(logTag .. 'Layer has changed!') end
    updateMaterialProperties()
  end
  im.PopItemWidth()
  if o.layer[0] > 0 then
    if im.Button("Move Up") then
      swapLayersWithUndo(o.layer[0] - 1, o.layer[0])
    end
  end
  if o.layer[0] < maxLayers - 1 then
    if o.layer[0] > 0 then im.SameLine() end
    if im.Button("Move Down") then
      swapLayersWithUndo(o.layer[0], o.layer[0] + 1)
    end
  end
end

local function moveCurrentMaterialToFile()
  if not currentMaterial then return end
  local currentFilename = currentMaterial:getFilename()
  local dialogPath = lastPath
  if currentFilename and #currentFilename > 0 then
    local dir = path.split(currentFilename)
    if dir and #dir > 0 then dialogPath = dir end
  end
  editor_fileDialog.saveFile(
    function(data)
      if editor.moveMaterial(currentMaterial, data.filepath) then
        local matName = currentMaterial:getField("name", 0)
        getMaterials()
        selectMaterialByName(matName)
        editor.showNotification("Material '" .. matName .. "' moved to '" .. data.filepath .. "'.")
      end
    end,
    {{"Material file", ".materials.json"}},
    false,
    dialogPath,
    "File already exists.\nDo you want to move the material into this file?"
  )
end

local function materialInfo()
  if im.BeginPopup("EDITMATERIALNAME") then
    im.TextUnformatted("Edit material name")
    if im.InputText("Material name", editor.getTempCharPtr(editMatName), nil, im.flags(im.InputTextFlags_AutoSelectAll)) then
      editMatName = editor.getTempCharPtr()
    end
    if im.Button("Cancel") then
      im.CloseCurrentPopup()
    end
    im.SameLine()
    if im.Button("Save") then
      local oldMaterialName = currentMaterial:getField('name', 0)
      local materialFilename = currentMaterial:getFilename()
      currentMaterial:setField('name', 0, editMatName)
      saveCurrentMaterial()
      getMaterials()
      editor.removeMaterialFromJson(oldMaterialName, materialFilename)
      im.CloseCurrentPopup()
    end
    im.EndPopup()
  end

  if im.CollapsingHeader1("Material Info", im.TreeNodeFlags_DefaultOpen) then
    im.Columns(2, "Material Properties##materialInfo")
    setMaterialPropertiesColumnWidth()

    -- Name
    im.TextUnformatted("Name")
    im.NextColumn()
    text("name", 0)

    local residesInJson = false
    if currentMaterial:getFilename() then
      local _,_,extension = path.split(currentMaterial:getFilename())
      residesInJson = (extension == "json")
    end

    if not residesInJson then im.BeginDisabled() end
    if editor.uiButtonRightAlign("Edit name", nil, true) then
      editMatName = currentMaterial:getField("name", 0)
      im.OpenPopup("EDITMATERIALNAME")
    end
    if not residesInJson then im.EndDisabled() end
    if residesInJson then
      im.tooltip("Edit current material's name.\nChanges won't take effect until reloading the map.")
    else
      if im.IsItemHovered() then
        im.BeginTooltip()
        im.TextUnformatted("Edit current material's name.\nChanges won't take effect until reloading the map.")
        im.TextColored(editor.color.warning.Value, "Warning: Material can't be renamed.\nMaterial needs to reside in a json file.")
        im.EndTooltip()
      end
    end
    im.NextColumn()

    -- MapTo
    im.TextUnformatted("Map To")
    im.NextColumn()
    inputText(nil, "mapTo", 0, true, -(v.inputWidgetHeight * im.uiscale[0] + 10))
    im.SameLine()
    if editor.uiIconImageButton(
      editor.icons.material_pick_mapto,
      im.ImVec2(v.inputWidgetHeight, v.inputWidgetHeight),
      pickMaterialFromObject and editor.color.white.Value or editor.color.grey.Value,
      nil, nil, "matInfoPickMapTo"
    ) and pickingFromObjectMode ~= pickingFromObjectMode_enum.from_object_selection then
      pickingFromObjectMode = pickingFromObjectMode_enum.existing_material
      pickMaterialFromObject = not pickMaterialFromObject
      if pickMaterialFromObject == true then
        formerEditMode = editor.editMode
        editor.selectEditMode(getPickMaterialEditMode())
      else
        editor.selectEditMode(formerEditMode)
        formerEditMode = nil
      end
    end
    im.tooltip("Enable to pick a material from a mesh.")
    im.NextColumn()

    -- Path
    local filepath = currentMaterial:getFilename()
    local dir, filename, ext = "", "", ""
    if filepath then
      dir, filename, ext = path.splitWithoutExt(filepath)
    end

    im.TextUnformatted("Directory")
    im.NextColumn()
    im.TextUnformatted(dir)
    im.NextColumn()

    im.TextUnformatted("Filename")
    im.NextColumn()
    im.TextUnformatted(string.format("%s.%s", filename, ext))
    if editor.uiButtonRightAlign("Open in explorer", nil, true) then
      local p = resolvePath(filepath)
      if p and p ~= "" and FS:fileExists(p) then Engine.Platform.exploreFolder(p) else log('E', '', 'Path :'..p..' does not exist' ) end
    end
    im.NextColumn()

    -- Move material to another file
    im.TextUnformatted("Move")
    im.NextColumn()
    if not residesInJson then im.BeginDisabled() end
    if im.Button("Move To File...") then
      moveCurrentMaterialToFile()
    end
    if not residesInJson then im.EndDisabled() end
    if residesInJson then
      im.tooltip("Move this material to another materials.json file (existing or new).\nThe material will be removed from the current file.\nChanges won't take effect until reloading the map.")
    else
      if im.IsItemHovered() then
        im.BeginTooltip()
        im.TextUnformatted("Move this material to another materials.json file.")
        im.TextColored(editor.color.warning.Value, "Warning: Material can't be moved.\nMaterial needs to reside in a json file.")
        im.EndTooltip()
      end
    end
    im.NextColumn()

    -- Version
    local version = tonumber(currentMaterial:getField('version', 0))
    im.TextUnformatted("Version")
    if version > 1 then
      im.ShowHelpMarker("Choose if to use the old material system, or the newer one based on Physically Based Rendering.\n" ..
      "In v1.5, BaseColor must be in sRGB colorspace, while other textures must be in linear colorspace.\n" ..
      "We recommend to use v1.5 along with the Texture Cooker feature.\nMore info in the Official Documentation (F1)", true)
    elseif version < 1.5 then
      im.ShowHelpMarker("Choose if to use the old material system, or the newer one based on Physically Based Rendering.\n" ..
      "In v1 all textures are expected to be in sRGB colorspace", true)
    end

    im.NextColumn()
    im.TextUnformatted(currentMaterial:getField('version', 0))
    im.SameLine()

    if version and version < 1.5 then
      im.PushStyleColor2(im.Col_Button, im.ImVec4(0, .5, 0, 0.5))
      im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(0, .7, 0, 0.6))
      im.PushStyleColor2(im.Col_ButtonActive, im.ImVec4(0, .8, 0, 0.7))
      if im.Button("Switch to V1.5 (PBR)") then
        currentMaterial:setField('glow', 0, '0')
        currentMaterial:setField('version', 0, '1.5')
        currentMaterial:reload()
        setMaterialDirty()
        v.totalTexSize.dirty = true
      end
      im.PopStyleColor(3)
    end

    -- disabled for now
    if version and version > 1 then
      if im.Button("Revert to V1") then
        currentMaterial:setField('version', 0, '1')
      end
    end
    if editor.uiButtonRightAlign("Find objects using this material", nil, true) then
      local matName = currentMaterial and currentMaterial:getField("name", 0)
      if matName and matName ~= "" then
        computeMaterialUsageForMatName(matName)
        editor.showWindow(materialUsageWindowName)
      else
        editor.showNotification("No material selected or invalid material name.")
      end
    end

    im.NextColumn()

    -- Active Layers
    if version and version > 1 then
      im.TextUnformatted("Active Layers")
      im.NextColumn()
      im.TextUnformatted(tostring(currentMaterial.activeLayers) .. ' of ' .. tostring(maxLayers))
      im.SameLine()

      local disabled = currentMaterial.activeLayers >= maxLayers
      if disabled then im.BeginDisabled() end
      if im.Button("+") then
        if currentMaterial.activeLayers < maxLayers then
          setPropertyWithUndo('activeLayers', 0, currentMaterial.activeLayers + 1)
        end
      end
      if disabled then im.EndDisabled() end
      im.tooltip(currentMaterial.activeLayers >= maxLayers and "You can't have more than " .. tostring(maxLayers) .. " layers" or "Add layer")
      im.SameLine()
      disabled = currentMaterial.activeLayers <= 1
      if disabled then im.BeginDisabled() end
      if im.Button("-") then
        if currentMaterial.activeLayers > 1 then
          setPropertyWithUndo('activeLayers', 0, currentMaterial.activeLayers - 1)
        end
      end
      if disabled then im.EndDisabled() end
      im.tooltip(currentMaterial.activeLayers <= 1 and "You have to have at least one layer" or "Remove layer")
      im.NextColumn()
    end
    im.TextUnformatted("Est. size")
    im.ShowHelpMarker("Displays the estimated total GPU memory used by all textures in this material.\nActual usage varies with the MIP levels currently loaded.\nFor detailed statistics use Performance Graph GPU Memory Profiling (CTRL + SHIFT + F).", true)
    im.NextColumn()
    local totalSize = computeTotalTextureSize(currentMaterial)
    im.TextUnformatted(string.format("%.2f MB", totalSize / 1e6))
    --
    im.Columns(1)
  end
end

local function basicTextureMaps()
  if im.CollapsingHeader1("Basic Properties", im.TreeNodeFlags_DefaultOpen) then
    -- Color Map
    imageButton("Color Map", "diffuseMap", nil, function()
      -- Color Map Color
      colorEdit4("Color", "diffuseColor", nil, nil, true)
      local availWidth = im.GetContentRegionAvailWidth()
      checkbox("Instance Diffuse", "instanceDiffuse", nil, "If enabled the material multiplies the color value by the SimObject's instanceColor value.")
      if availWidth > 240 then
        im.SameLine(nil, 20)
      end
      -- Vertex Color
      checkbox("Vertex Color", "vertColor")
    end)
    im.Separator()
    -- Normal Map
    imageButton('Normal Map', "normalMap")
    im.Separator()
    -- Specular Map
    imageButton("Specular Map", "specularMap")
  end
end

local function advancedTextureMaps()
  if im.CollapsingHeader1("Advanced Properties") then
    -- Reflectivity Map
    imageButton("Reflectivity Map", "reflectivityMap", nil, function()
      sliderFloat("Reflectivity Map Factor", "reflectivityMapFactor", 0, 1)
      if currentMaterial:getField("reflectivityMap", o.layer[0]) ~= "" and currentMaterial:getField("cubemap", 0) == "" then
        im.TextColored(editor.color.warning.Value, "The cubemap for this material is not set.\nThe reflectivity map won't work without a cubemap assigned to this material.")
      end
    end)
    im.Separator()

    -- Detail Map
    imageButton("Detail Map", "detailMap", nil, function()
      -- Detail Map Scale
      inputFloat2("Scale:", "detailScale", "%.2f")
    end)
    im.Separator()

    -- Detail Normal Map
    imageButton("Detail Normal Map", "detailNormalMap", nil, function()
      -- Detail Normal Map Strength
      inputFloat("Detail Normal Map Strength", "detailNormalMapStrength")
    end)
    im.Separator()

    -- Overlay Map
    imageButton("Overlay Map", "overlayMap", nil, function()
      im.TextUnformatted("This texture uses the 2nd UV channel")
    end)
    im.Separator()

    -- Color Palette Map
    imageButton("Color Palette Map", "colorPaletteMap", nil, function()
      combo("Color Palette Map UV Layer", "colorPaletteMapUV", {"0", "1"})
    end)
    im.Separator()

    -- Opacity Map
    imageButton("Opacity Map", "opacityMap")
  end
end

local function deprecatedFeatures()
  if im.CollapsingHeader1("Deprecated Features") then
    -- Vertex Lit
    checkbox("Vertex Lit", "vertLit", nil, "Enables the use of vertex lightning for this layer.")

    -- Minnaert Constant
    inputFloat("Minnaert Constant", "minnaertConstant", 0.1, 1, "%.1f")
  end
end

local function lightingProperties()
  if im.CollapsingHeader1("Lighting Properties") then
    -- Specular
    checkbox("Pixel Specular", "pixelSpecular")
    colorEdit4("Specular Color", 'specular')
    sliderFloat("Roughness Factor", "roughnessFactor", 0, 1)
    -- Emissive
    checkbox("Emisive", "emissive")
    inputFloat("Emissive Intensity (nits)", "emissiveIntensityNits", nil, nil, nil, nil, "Physical emissive intensity in nits.")
    -- Glow
    checkbox("Glow", "glow")
    colorEdit4("Glow Factor", 'glowFactor')
    -- Anisotropic Filtering
    checkbox("Anisotropic filtering", "useAnisotropic")
  end
end

local function animationProperties(layer)

  if im.CollapsingHeader1("Animation Properties" .. (layer and "##" .. tostring(layer) or "")) then
    -- Rotation Animation
    checkboxFlag("Rotation Animation", "animFlags", enum_animFlags.rotate, layer)
    sliderFloat2("Rotation Pivot Offset", "U", "V", "rotPivotOffset", -1, 0, nil, layer)
    sliderFloat("Rotation Animation Speed", "rotSpeed", nil, nil, nil, layer)
    im.Separator()
    -- Scroll Animation
    checkboxFlag("Scroll Animation ", "animFlags", enum_animFlags.scroll, layer)
    sliderFloat2(nil, "U", "V", "scrollDir", -1, 1, nil, layer)
    sliderFloat("Scroll Animation Speed", "scrollSpeed", 0, 10, nil, layer)
    im.Separator()

    -- Wave Animation
    checkboxFlag("Wave Animation", "animFlags", enum_animFlags.wave, layer)
    im.TextUnformatted("Wave Type")
    radio("Wave Type", "Sin", "waveType", "Sin", layer)
    im.SameLine()
    radio("Wave Type", "Square", "waveType", "Square", layer)
    im.SameLine()
    radio("Wave Type", "Triangle", "waveType", "Triangle", layer)
    im.SameLine()
    checkboxFlag("Scale", "animFlags", enum_animFlags.scale, layer)
    sliderFloat("Amplitude", "waveAmp", nil, nil, nil, layer)
    sliderFloat("Frequency", "waveFreq", 0, 10, nil, layer)
    im.Separator()

    -- Image Sequence
    checkboxFlag("Image Sequence", "animFlags", enum_animFlags.sequence, layer)
    sliderFloat("Frames / Sec", "sequenceFramePerSec", 0, 30, nil, layer)
    sliderFloat("Frames", "sequenceSegmentSize", 0, 100, nil, layer)
  end
end

local function alphaBlendCombo()
  local version = tonumber(currentMaterial:getField('version', 0)) or 1

  local items = version >= 1.5 and {"None", "PreMulAlpha", "Add", "AddAlpha", "LerpAlpha", "Mul", "Sub"} or {"None", "Add", "AddAlpha", "LerpAlpha", "Mul", "Sub"}
  local cptr = im.ArrayCharPtrByTbl(items)

  --Translucent Blend Operation
  local translucent = currentMaterial:getField("translucent", 0)
  local translucentBlendOp = currentMaterial:getField("translucentBlendOp", 0)

  local index = -1
  if translucent == "0" or translucentBlendOp == "None" then
    index = 0
  else
    for k, v in pairs(items) do
      if v == translucentBlendOp then
        index = (k - 1)
        break
      end
    end
  end

  im.TextUnformatted("Alpha Blend Mode")
  im.SameLine()
  im.PushItemWidth(im.GetContentRegionAvailWidth() - 10)
  if im.Combo1("##Alpha Blend Mode_translucent0", editor.getTempInt_StringString(index), cptr) then
    local value = items[tonumber(editor.getTempInt_StringString()) + 1]
    if value == "None" then
      setProperty(currentMaterial, 'translucent', 0, "0")
      setProperty(currentMaterial, 'translucentBlendOp', 0, "None")
    else
      setProperty(currentMaterial, 'translucent', 0, "1")
      setProperty(currentMaterial, 'translucentBlendOp', 0, value)
    end
  end
  im.PopItemWidth()
end

local function advanced()
  if im.CollapsingHeader1("Advanced - All Layers") then
    local version = tonumber(currentMaterial:getField('version', 0)) or 1

    alphaBlendCombo()

    checkbox("Z-Write", "translucentZWrite", 0, "When enabled writes this translucent material to the depth buffer. Use when translucent material should render on top of opaque material.")
    im.SameLine()
    checkbox("Receive shadows", "translucentRecvShadows", 0, "When enabled translucent material can receive shadows.")

    im.Separator()
    -- alphaTest
    checkbox("Alpha Clip", "alphaTest", 0, "Enable to clip out trasnparent pixels from material.")
    im.SameLine()
    sliderInt("Alpha Clip Threshold", "alphaRef", 0, 255, nil, 0)

    checkbox("Double Sided", "doubleSided", 0, "Make material double sided.")
    im.SameLine()
    checkbox("Invert backface normals", "invertBackFaceNormals", 0, "Backfaces will appear with corrected normal.")
    checkbox("Cast Shadows", "castShadows", 0, "Material can cast it's own shadows.")
    -- Subsurface translucency
    if version >= 1.5 then
      im.SameLine()
      checkbox("Subsurface Scattering", "subSurface", nil, "Thin surface translucency for backface lighting (e.g. foliage).")
      sliderFloat("Subsurface Intensity", "subSurfaceIntensity", 0, 1)
    end
    im.Separator()

    cubemap()
  end
end

local function annotationWidget()
  local annotations = editor.getAnnotations()
  local annotationsTbl = editor.getAnnotationsTbl()
  local bgColor = nil
  local value = currentMaterial:getField("annotation", 0)
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
  im.Columns(2, "Material Properties##annotation")
  setMaterialPropertiesColumnWidth()
  im.TextUnformatted("Annotation")
  im.NextColumn()
  im.ColorButton("Annotation color", bgColor, 0, im.ImVec2(25, 19))
  im.SameLine()
  im.PushItemWidth(im.GetContentRegionAvailWidth() - 10)
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
        setPropertyWithUndo('annotation', 0, value)
      end
      if isSelected then
        -- set the initial focus when opening the combo
        im.SetItemDefaultFocus()
      end
    end
    im.EndCombo()
    im.NextColumn()
    im.Columns(1)
  end
  im.PopItemWidth()
end

local function additionalInfo()
  if im.CollapsingHeader1("Additional Info") then
    im.Columns(2, "Material Properties##additionalInfo")
    setMaterialPropertiesColumnWidth()
    im.TextUnformatted("Material Tag 0")
    im.NextColumn()
    inputText(nil, "materialTag", 0, true, nil, function() core_jobsystem.create(mapTagsJob, 1) end)
    im.NextColumn()

    im.TextUnformatted("Material Tag 1")
    im.NextColumn()
    inputText(nil, "materialTag", 1, true, nil, function() core_jobsystem.create(mapTagsJob, 1) end)
    im.NextColumn()

    im.TextUnformatted("Material Tag 2")
    im.NextColumn()
    inputText(nil, "materialTag", 2, true, nil, function() core_jobsystem.create(mapTagsJob, 1) end)
    im.NextColumn()
    im.Columns(1)

    im.Separator()

    if groundModels then
      combo("Ground Type", "groundType", groundModels, 0, "Material Properties")
    end

    fileWidget(
      "Annotation Map",
      "annotationMap",
      0,
      {{"Any files", "*"},{"PNG",".png"}},
      "Material Properties"
    )

    annotationWidget()
  end
end

local function materialPropertiesVersion0()
  basicTextureMaps()
  advancedTextureMaps()
  deprecatedFeatures()

  lightingProperties()
  animationProperties()
  advanced()
  additionalInfo()
end

local useCTState = useCTState or {}

local function materialPropertiesVersion1()
  for i = 1, currentMaterial.activeLayers do
    local lyr = i - 1
    if im.CollapsingHeader1("Layer " .. tostring(i), i == 1 and im.TreeNodeFlags_DefaultOpen or nil) then
      im.Indent()

      if lyr > 0 then
        if im.Button("Move Up##layer"..tostring(lyr)) then
          swapLayersWithUndo(lyr - 1, lyr)
        end
      end

      if lyr < currentMaterial.activeLayers - 1 then
        if lyr > 0 then im.SameLine() end
        if im.Button("Move Down##layer"..tostring(lyr)) then
          swapLayersWithUndo(lyr, lyr + 1)
        end
      end

      if im.CollapsingHeader1("Basic Properties##" .. tostring(lyr), im.TreeNodeFlags_DefaultOpen) then
        -- Color Map
        imageButton("BaseColor Map", "diffuseMap", lyr, function()
          colorEdit4("Color", "diffuseColor", nil, lyr, true)
          combo("UV Layer", "diffuseMapUV", {"0", "1"}, lyr)
          local availWidth = im.GetContentRegionAvailWidth()
          checkbox("Instance BaseColor", "instanceDiffuse", lyr, "If enabled the material multiplies the color value by the SimObject's instanceColor value.")
          if availWidth > 240 then
            im.SameLine(nil, 20)
          end
          -- Vertex Color
          checkbox("Vertex Color", "vertColor", lyr, "If enabled the material multiplies the color value by the vertex color value.")
        end)
        im.Separator()

        -- Detail Map Scale,
        im.TextUnformatted("Detail Map")
        inputFloat2("Scale:", "detailScale", "%.2f", lyr)
        im.Separator()

        -- Color Detail Map
        imageButton("BaseColor Detail Map", "detailMap", lyr, function()
          inputFloat("Strength:", "detailBaseColorMapStrength", nil, nil, nil, lyr)
          combo("UV Layer", "detailMapUV", {"0", "1"}, lyr)
        end)
        im.Separator()

        -- Metallic Factor
        imageButton("Metallic Map", "metallicMap", lyr, function()
          sliderFloat("Factor", "metallicFactor", 0, 1, nil, lyr)
          combo("UV Layer", "metallicMapUseUV", {"0", "1"}, lyr)
        end)
        im.Separator()

        -- Metallic Detail Map
        imageButton("Metallic Detail Map", "metallicDetailMap", lyr, function()
          sliderFloat("Strength", "detailMetallicMapStrength", 0, 1, nil, lyr)
        end)
        im.Separator()

        -- Normal Map
        imageButton('Normal Map', "normalMap", lyr, function()
          inputFloat("Strength", "normalMapStrength", nil, nil, nil, lyr)
          combo("UV Layer", "normalMapUV", {"0", "1"}, lyr)
        end)
        im.Separator()
        -- Normal Detail Map
        imageButton("Normal Detail Map", "detailNormalMap", lyr, function()
          inputFloat("Normal Detail Map Strength", "detailNormalMapStrength", nil, nil, nil, lyr)
          combo("UV Layer", "normalDetailMapUV", {"0", "1"}, lyr)
        end)
        im.Separator()

        -- Roughness
        imageButton("Roughness Map", "roughnessMap", lyr, function()
          sliderFloat("Factor", "roughnessFactor", 0, 1, nil, lyr)
          combo("UV Layer", "roughnessMapUseUV", {"0", "1"}, lyr)
        end)
        im.Separator()

        -- Roughness Detail Map
        imageButton("Roughness Detail Map", "roughnessDetailMap", lyr, function()
          sliderFloat("Strength", "detailRoughnessMapStrength", 0, 1, nil, lyr)
        end)
        im.Separator()

        -- Opacity Map
        imageButton("Opacity Map", "opacityMap", lyr, function()
          sliderFloat("Factor", "opacityFactor", 0, 1, nil, lyr)
          combo("UV Layer", "opacityMapUV", {"0", "1"}, lyr)
          checkbox("Instance Opacity", "instanceOpacity", lyr, "If enabled the material multiplies the opacity value by the SimObject's instanceColor alpha value.")
        end)
        im.Separator()

        -- Opacity Detail Map
        imageButton("Opacity Detail Map", "opacityDetailMap", lyr, function()
          sliderFloat("Strength", "detailOpacityMapStrength", 0, 1, nil, lyr)
          combo("UV Layer", "opacityDetailMapUseUV", {"0", "1"}, lyr)
        end)
        im.Separator()

        -- AO Map
        imageButton("Ambient Occlusion Map", "ambientOcclusionMap", lyr, function()
          combo("UV Layer", "ambientOcclusionMapUseUV", {"0", "1"}, lyr)
        end)
        im.Separator()

        -- AO Detail Map
        imageButton("Ambient Occlusion Detail Map", "ambientOcclusionDetailMap", lyr, function()
          sliderFloat("Strength", "detailAoMapStrength", 0, 1, nil, lyr)
        end)
        im.Separator()
      end

      if im.CollapsingHeader1("Advanced Properties##" .. tostring(lyr)) then
        -- BaseColor Palette
        imageButton("BaseColor Palette Map", "colorPaletteMap", lyr, function()
          combo("UV Layer", "colorPaletteMapUV", {"0", "1"}, lyr)
          checkbox("Base Color", "paletteBaseColor", lyr); im.SameLine()
          checkbox("Roughness", "paletteRoughness", lyr); im.SameLine()
          checkbox("Metallic", "paletteMetallic", lyr)
          checkbox("Clear Coat", "paletteClearCoat", lyr); im.SameLine()
          checkbox("Clear Coat Roughness", "paletteClearCoatRoughness", lyr)
        end)
        im.Separator()

        -- Emissive
        imageButton("Emissive Map", "emissiveMap", lyr, function()
          combo("UV Layer", "emissiveMapUseUV", {"0", "1"}, lyr)
        end)

        local ctKey = tostring(currentMaterial:getId()) .. ":" .. tostring(lyr) .. ":emissiveFactor"
        local useCT = useCTState[ctKey] or false
        local useCTPtr = im.BoolPtr(useCT)
        if im.Checkbox("Use Color Temperature##" .. ctKey, useCTPtr) then
          useCT = useCTPtr[0]
          useCTState[ctKey] = useCT
        end
        im.ShowHelpMarker("Adjust emissive color with color temperature instead of RGB values to get more realistic light source color", true)
        colorEdit4("Factor", "emissiveFactor", nil, lyr)
        inputFloat("Intensity (nits)", "emissiveIntensityNits", nil, nil, nil, lyr, "Physical emissive intensity in nits.")

        if useCT then
          im.PushItemWidth(im.GetContentRegionAvailWidth() - 10)
          colorTempUI.draw({
            id = "mat_emissive_" .. tostring(currentMaterial:getId()) .. "_" .. tostring(lyr),
            label = "Color temperature",
            getRGBA = function()
              local v = stringToTable(currentMaterial:getField("emissiveFactor", lyr) or "")
              local r = tonumber(v[1]) or 1
              local g = tonumber(v[2]) or 1
              local b = tonumber(v[3]) or 1
              local a = tonumber(v[4]) or 1
              return r, g, b, a
            end,
            setRGBA = function(r, g, b, a, isFinal)
              local val = string.format("%.6f %.6f %.6f %.6f", r, g, b, a)
              if isFinal then
                setPropertyWithUndo("emissiveFactor", lyr, val)
              else
                setProperty(nil, "emissiveFactor", lyr, val)
              end
            end
          })
          im.PopItemWidth()
        end

        checkbox("Instance Emissive", "instanceEmissive", lyr, "If enabled the material multiplies the color value by the SimObject's instanceColor value.")
        im.SameLine()
        checkbox("Vertex color", "vertColorEmissive", lyr, "If enabled the material multiplies the vtx color value emissive value.")
        im.Separator()

        sliderFloat("Retro Reflectivity", "retroreflectivity", 0, 1, nil, lyr)
        im.TextUnformatted("Retro Reflectivity Color")
        local retroColor = stringToTable(currentMaterial:getField("retroreflectiveColor", lyr) or "")
        tempBoolPtr[0] = false
        im.PushItemWidth(im.GetContentRegionAvailWidth() - 10)
        if editor.uiColorEdit3(
          "##rgb_retroreflectiveColor" .. tostring(lyr),
          editor.getTempFloatArray3_TableTable({
            tonumber(retroColor[1]) or 0,
            tonumber(retroColor[2]) or 0,
            tonumber(retroColor[3]) or 0
          }),
          im.flags(im.ColorEditFlags_HDR),
          tempBoolPtr
        ) then
          local value = editor.getTempFloatArray3_TableTable()
          setProperty(nil, "retroreflectiveColor", lyr, string.format("%.6f %.6f %.6f", value[1], value[2], value[3]))
        end
        if tempBoolPtr[0] == true then
          local value = editor.getTempFloatArray3_TableTable()
          setPropertyWithUndo("retroreflectiveColor", lyr, string.format("%.6f %.6f %.6f", value[1], value[2], value[3]))
          tempBoolPtr[0] = false
        end
        im.PopItemWidth()
        im.ShowHelpMarker("Black applies retroreflectivity to every color. Any other color limits it to matching base colors.", true)
        im.Separator()

        -- clear coat
        imageButton("Clear Coat Map", "clearCoatMap", lyr, function()
          sliderFloat("Factor", "clearCoatFactor", 0, 1, nil, lyr)
          sliderFloat("Factor roughness", "clearCoatRoughnessFactor", 0, 1, nil, lyr)
          combo("UV Layer", "clearCoatMapUseUV", {"0", "1"}, lyr)
        end)
        im.Separator()
        imageButton("Clear Coat Bottom Normal Map", "clearCoatBottomNormalMap", lyr, function()
          inputFloat("Strength", "clearCoatBottomNormalMapStrength", nil, nil, nil, lyr)
        end)
        im.Separator()

        -- Anisotropic Filtering
        checkbox("Anisotropic filtering", "useAnisotropicFilter", lyr, "Enables anisotropic filtering for material.")
      end

      animationProperties(lyr)
      im.Unindent()
    end
  end

  advanced()
  additionalInfo()
end

local function materialPreview(previewSize)
  if previewSize then
    if extMatPreviewRenderSize ~= previewSize then
      extMatPreviewRenderSize = previewSize
      extDimRdr:set(0, 0, extMatPreviewRenderSize, extMatPreviewRenderSize)
      extMatPreview:renderWorld(extDimRdr)
    end

    local cPosA = im.GetCursorPos()
    extMatPreview:ImGui_Image(extMatPreviewRenderSize, extMatPreviewRenderSize)
    local cPosB = im.GetCursorPos()
    im.SetCursorPos(im.ImVec2(cPosA.x + im.GetStyle().ItemSpacing.y, cPosA.y + im.GetStyle().ItemSpacing.y))
    if editor.uiColorEdit3(
      "##extMaterialPreviewBackgroundColorEdit",
      editor.getTempFloatArray3_TableTable({extMatPreviewBackgroundColor.r/255,extMatPreviewBackgroundColor.g/255,extMatPreviewBackgroundColor.b/255}),
      im.ColorEditFlags_NoInputs
    ) then
      local val = editor.getTempFloatArray3_TableTable()
      extMatPreviewBackgroundColor.r = val[1] * 255
      extMatPreviewBackgroundColor.g = val[2] * 255
      extMatPreviewBackgroundColor.b = val[3] * 255
      extMatPreview.mBgColor = extMatPreviewBackgroundColor
      extMatPreview:renderWorld(extDimRdr)
    end
    im.tooltip("Background Color")
    im.SetCursorPos(cPosB)
    im.Dummy(im.ImVec2(0, 0))
  else
    if im.GetContentRegionAvailWidth() ~= matPreviewRenderSize or updateMaterialPreviewRender == true  then
      matPreviewRenderSize = im.GetContentRegionAvailWidth()
      matPreviewRenderSize = matPreviewRenderSize > options.maxMaterialPreviewSize and options.maxMaterialPreviewSize or matPreviewRenderSize
      dimRdr:set(0, 0, matPreviewRenderSize, matPreviewRenderSize)
      matPreview:renderWorld(dimRdr)
    end

    local cPosA = im.GetCursorPos()
    matPreview:ImGui_Image(matPreviewRenderSize, matPreviewRenderSize)
    local cPosB = im.GetCursorPos()
    im.SetCursorPos(im.ImVec2(cPosA.x + im.GetStyle().ItemSpacing.y, cPosA.y + im.GetStyle().ItemSpacing.y))
    if editor.uiColorEdit3(
      "##materialPreviewBackgroundColorEdit",
      editor.getTempFloatArray3_TableTable({matPreviewBackgroundColor.r/255,matPreviewBackgroundColor.g/255,matPreviewBackgroundColor.b/255}),
      im.ColorEditFlags_NoInputs
    ) then
      local val = editor.getTempFloatArray3_TableTable()
      matPreviewBackgroundColor.r = val[1] * 255
      matPreviewBackgroundColor.g = val[2] * 255
      matPreviewBackgroundColor.b = val[3] * 255
      matPreview.mBgColor = matPreviewBackgroundColor
    end
    im.tooltip("Background Color")
    im.SetCursorPos(cPosB)
    im.Dummy(im.ImVec2(0, 0))
  end
end

local function drawGui()
  if currentMaterial then
    scanTextureIssues(currentMaterial)

    if editor.isWindowVisible(materialPreviewWindowName) == false then
      if im.CollapsingHeader1("Material Preview", im.TreeNodeFlags_DefaultOpen) then
        materialPreview()
        if im.Button("Open in dedicated window") then
          editor.showWindow(materialPreviewWindowName)
        end
      end
    end

    im.Dummy(im.ImVec2(0,4))
    materialInfo()
    im.Dummy(im.ImVec2(0,4))

    local version = tonumber(currentMaterial:getField("version", 0))
    if version then
      if version >= 2 then
        --
      elseif version >= 1.5 then
        materialPropertiesVersion1()
      else
        layer()
        materialPropertiesVersion0()
      end
    else
      layer()
      materialPropertiesVersion0()
    end
  else
    im.TextUnformatted("No material selected!")
  end
end

local function showMaterialEditor()
  if editor.isWindowVisible(toolWindowName) == false then
    editor.showWindow(toolWindowName)
  else
    focusWindow = true
  end
end

local function menuGui()
  if im.BeginPopup("DeleteCurrentMaterial") then
    im.TextUnformatted("Are you sure you want to delete the current material?")
    if im.Button("Cancel") then
      im.CloseCurrentPopup()
    end
    im.SameLine()
    if im.Button("Ok") then
      editor.deleteMaterial(currentMaterial)
      getMaterials()
      im.CloseCurrentPopup()
    end
    im.Dummy(im.ImVec2(0, v.style.FramePadding.y))
    im.EndPopup()
  end

  local wpos = im.GetWindowPos()
  local cpos = im.GetCursorPos()
  local p1 = im.ImVec2(wpos.x + cpos.x - v.style.WindowPadding.x, wpos.y + cpos.y - v.style.WindowPadding.y)
  local p2 = im.ImVec2(wpos.x + cpos.x + im.GetContentRegionAvailWidth() + 2 * v.style.WindowPadding.x, wpos.y + cpos.y + v.inputWidgetHeight * 1.5)
  im.ImDrawList_AddRectFilled(im.GetWindowDrawList(), p1, p2, im.GetColorU321(im.Col_MenuBarBg))
  im.PushStyleVar2(im.StyleVar_WindowPadding, im.ImVec2(6, 2))
  im.PushStyleColor2(im.Col_Button, im.ImVec4(1,0.5647,0,1))
  if editor.uiIconImageButton(editor.icons.material_new, im.ImVec2(v.inputWidgetHeight * 1.5, v.inputWidgetHeight * 1.5)) then
    local defaultPath = currentMaterial and currentMaterial:getFilename() or nil
    if not defaultPath or #defaultPath == 0 then
      defaultPath = (lastCreateMaterialPath or "/") .. "main.materials.json"
    end
    ffi.copy(newMatPath, defaultPath)
    editor.showWindow(createMaterialWindowName)
  end
  im.tooltip("New material")

  im.SameLine(nil, v.style.ItemSpacing.x)
  if editor.uiIconImageButton(editor.icons.material_tag, im.ImVec2(v.inputWidgetHeight * 1.5, v.inputWidgetHeight * 1.5)) then
    editor.showWindow(materialsByTagsWindowName)
  end
  im.tooltip("Open materials by tag window")

  im.SameLine(nil, v.style.ItemSpacing.x)
  if editor.uiIconImageButton(editor.icons.refresh, im.ImVec2(v.inputWidgetHeight * 1.5, v.inputWidgetHeight * 1.5)) then
    if currentMaterial then
      local maxLayers = currentMaterial.activeLayers
      local files = {}
      for k,v in pairs(currentMaterial:getFields()) do
        if v.type == "filename" then
          for i=0,maxLayers-1 do
            local filepath = currentMaterial:getField(k, i)
            if filepath ~= "" and string.sub(filepath, 1, 1) ~= '/' then
              filepath = "/"..filepath
            end
            if filepath ~= "" and FS:fileExists(filepath) then
              log("D", "reloadTex", dumps(k).."["..dumps(i).."]="..dumps(filepath))
              files[#files+1] = filepath
            end
          end
        end
      end
      if #files > 0 then
        FS:triggerFilesChanged(files)
      end
    else
      log("E","reloadTex", "no current mat")
    end
  end
  im.tooltip("Reload textures of current material")

  if currentMaterial and currentMaterial:getFilename() then
    im.SameLine(nil, v.style.ItemSpacing.x)
    local _,_,extension = path.split(currentMaterial:getFilename())
    local residesInJson = (extension == "json")
    if not residesInJson then im.BeginDisabled() end
    if editor.uiIconImageButton(editor.icons.delete, im.ImVec2(v.inputWidgetHeight * 1.5, v.inputWidgetHeight * 1.5)) then
      im.OpenPopup("DeleteCurrentMaterial")
    end
    if not residesInJson then im.EndDisabled() end
    if residesInJson then
      im.tooltip("Delete current material.\nChanges won't take effect until reloading the map.")
    else
      if im.IsItemHovered() then
        im.BeginTooltip()
        im.TextUnformatted("Delete current material.\nChanges won't take effect until reloading the map.")
        im.TextColored(editor.color.warning.Value, "Warning: Material can't be deleted.\nMaterial needs to reside in a json file.")
        im.EndTooltip()
      end
    end
  end

  im.PopStyleColor()
  im.PopStyleVar()

  im.SameLine()
  im.Spacing()
  editor.uiVertSeparator(32, im.ImVec2(0,0))
  im.Spacing()
  im.SameLine()

  local bgColor
  if pickingFromObjectMode == pickingFromObjectMode_enum.from_object_selection then
    bgColor = im.ImColorByRGB(255,102,0,255).Value
  end
  if editor.uiIconImageButton(editor.icons.material_pick_mapto, im.ImVec2(v.inputWidgetHeight * 1.5, v.inputWidgetHeight * 1.5), nil, nil, bgColor) then
    pickingFromObjectMode = pickingFromObjectMode_enum.from_object_selection
    pickMaterialFromObject = not pickMaterialFromObject
    if pickMaterialFromObject == true then
      formerEditMode = editor.editMode
      editor.selectEditMode(getPickMaterialEditMode())
    else
      editor.selectEditMode(formerEditMode)
      formerEditMode = nil
      pickingFromObjectMode = nil
    end
  end
  im.tooltip("Pick an Object From Scene To Show its Materials")

  im.SameLine()

  if editor.uiIconImageButton(editor.icons.public, im.ImVec2(v.inputWidgetHeight * 1.5, v.inputWidgetHeight * 1.5)) then
    editor.clearObjectSelection()
    if editor_forestEditor then
      editor_forestEditor.clearForestItemsSelection()
    end
    rayPickMaterialNameList = nil
    pickMaterialsFromObjectName = nil
    getMaterials()
  end
  im.tooltip("Shows All Loaded Materials")

  if pickMaterialsFromObjectName then
    im.SameLine()
    im.TextColored(im.ImVec4(1, 1, 0, 1), "From: " .. pickMaterialsFromObjectName)
  end

  im.Dummy(im.ImVec2(0, v.style.ItemSpacing.y))
end

local function pickFromTSStaticGui()
  if pickMapToFromObjectPopupPos then
    im.SetWindowPos1(pickMapToFromObjectPopupPos, im.Cond_Appearing)
  else
    im.SetWindowPos1(im.GetMousePos(), im.Cond_Appearing)
  end
  if pickMapToFromObjectPopupHeight then im.SetNextWindowSize(im.ImVec2(0, pickMapToFromObjectPopupHeight)) end
  if im.BeginPopup("PickMapToFromObjectPopup") then
    local maxWidth = im.GetContentRegionAvailWidth()
    if pickingFromObjectMaterials then
      for _, matName in ipairs(pickingFromObjectMaterials) do
        if im.Selectable1(matName) then
          if pickingFromObjectMode == pickingFromObjectMode_enum.new_material then
            ffi.copy(newMatMapTo, matName)
          elseif pickingFromObjectMode == pickingFromObjectMode_enum.existing_material then
            setPropertyWithUndo("mapTo", 0, matName)
          end
          pickingFromObjectMaterials = nil
          pickMaterialFromObject = false
          if formerEditMode then
            editor.selectEditMode(formerEditMode)
            formerEditMode = nil
          end
          im.CloseCurrentPopup()
        end
        if im.IsItemHovered() then
          if maxWidth < (im.CalcTextSize(matName).x + 2 * v.style.WindowPadding.x) then
            im.SetTooltip(matName)
          end
        end
      end
    end
    im.EndPopup()
  end
end

local function materialsByTagWindowGui()
  if editor.beginWindow(materialsByTagsWindowName, "Materials by Tag") then
    if sortedTags then
      for _, tagName in ipairs(sortedTags) do
        if im.TreeNodeEx1(tagName) then
          for _, material in ipairs(tags[tagName]) do
            if im.SmallButton(material) then
              -- Clear search filter before selecting a material, it might not be part of the mat list yet.
              im.TextFilter_SetInputBuf(matFilter, "")
              rayPickMaterialNameList = nil
              pickMaterialsFromObjectName = nil
              getMaterials()
              selectMaterialByName(material)
            end
          end
          im.TreePop()
        end
      end
    end
  end
  editor.endWindow()
end

local function createMaterialWindowGui()
  if editor.beginWindow(createMaterialWindowName, "Create Material") then
    local cursorPosY = im.GetCursorPosY()
    im.Text("Material Name:")
    im.SameLine()
    im.PushItemWidth(im.GetContentRegionAvailWidth() - (v.inputWidgetHeight * im.uiscale[0] + v.style.ItemSpacing.x + 10))
    im.InputText("##NewMatName", newMatName, nil, im.flags(im.InputTextFlags_CharsNoBlank))
    im.PopItemWidth()

    im.SameLine()
    local size = im.ImVec2(v.inputWidgetHeight, 2* v.inputWidgetHeight + v.style.ItemSpacing.y)
    local pos = im.GetCursorPos()
    if editor.uiIconImageButton((newMatMapToLocked == true and editor.icons.lock_outline or editor.icons.lock_open), size, im.ImVec4(1,1,1,0)) then
      newMatMapToLocked = not newMatMapToLocked
      if newMatMapToLocked == true and #ffi.string(newMatName) == 0 and #ffi.string(newMatMapTo) > 0 then
        ffi.copy(newMatName, ffi.string(newMatMapTo))
      end
    end
    im.SetCursorPos(im.ImVec2(pos.x,pos.y + size.y/4))
    editor.uiIconImage((newMatMapToLocked == true and editor.icons.lock_outline or editor.icons.lock_open), im.ImVec2(size.x, size.x))
    -- icon, size, col, borderCol, label
    im.SetCursorPosY(cursorPosY + v.inputWidgetHeight + v.style.ItemSpacing.y)
    im.Text("Map to:")
    im.SameLine()
    if newMatMapToLocked == true then
      im.PushItemWidth(im.GetContentRegionAvailWidth() - (v.inputWidgetHeight * im.uiscale[0] + v.style.ItemSpacing.x + 10))
    else
      im.PushItemWidth(im.GetContentRegionAvailWidth() - (v.inputWidgetHeight * im.uiscale[0] + 3 * v.style.ItemSpacing.x + im.CalcTextSize("Pick from TSStatic").x + 10))
    end
    im.InputText("##NewMatMapTo", (newMatMapToLocked == true and newMatName or newMatMapTo), nil, im.flags(im.InputTextFlags_CharsNoBlank))
    im.PopItemWidth()
    if newMatMapToLocked == false then
      im.SameLine()
      im.PushStyleColor2(im.Col_Button, pickMaterialFromObject and im.GetStyleColorVec4(im.Col_ButtonActive) or im.GetStyleColorVec4(im.Col_Button))
      if im.Button("Pick from TSStatic") then
        pickMaterialFromObject = true
        pickingFromObjectMode = pickingFromObjectMode_enum.new_material
        if pickMaterialFromObject == true then
          formerEditMode = editor.editMode
          editor.selectEditMode(getPickMaterialEditMode())
        else
          editor.selectEditMode(formerEditMode)
          formerEditMode = nil
        end
      end
      im.tooltip("Enable to pick a material from a mesh.")
      im.PopStyleColor()
    end

    im.Text("Path:")
    im.SameLine()
    im.PushItemWidth(im.GetContentRegionAvailWidth() - (v.style.ItemSpacing.x + 2 * v.style.FramePadding.x + im.CalcTextSize("...").x))
    im.InputText("##NewMatPath", newMatPath, nil, im.flags(im.InputTextFlags_CharsNoBlank))
    im.PopItemWidth()
    im.SameLine()
    if im.Button("...") then
      local currentPath = ffi.string(newMatPath)
      local dialogPath = lastCreateMaterialPath
      if currentPath and #currentPath > 0 then
        local dir = path.split(currentPath)
        if dir and #dir > 0 then
          dialogPath = dir
        end
      end
      editor_fileDialog.saveFile(
        function(data)
          lastCreateMaterialPath = data.path
          ffi.copy(newMatPath, data.filepath)
        end,
        {{"Any files", "*"},{"Material file",".materials.json"}},
        false,
        dialogPath,
        "File already exists.\nDo you want to merge the material into this file?"
      )
    end

    if createMaterialName ~= ffi.string(newMatName) then
      createMaterialName = ffi.string(newMatName)
      local mat = scenetree.findObject(createMaterialName)
      if mat then
        createMaterialMessage = "Error: Object with name \""..createMaterialName.."\" already exists. Please choose a different name."
        createMaterialError = true
      else
        createMaterialMessage = ""
        createMaterialError = false
      end
    end

    im.SetCursorPosX(im.GetCursorPosX() + im.GetContentRegionAvailWidth() - (v.style.ItemSpacing.x + 4 * v.style.FramePadding.x + im.CalcTextSize("Create").x + im.CalcTextSize("Cancel").x))
    if createMaterialError then im.BeginDisabled() end
    if im.Button("Create") then
      if editor.createMaterial(ffi.string(newMatName), ffi.string(newMatPath), (newMatMapToLocked == true and ffi.string(newMatName) or ffi.string(newMatMapTo))) then
        editor.hideWindow(createMaterialWindowName)
        local createdName = ffi.string(newMatName)
        if rayPickMaterialNameList then
          local already = false
          for _, n in ipairs(rayPickMaterialNameList) do
            if n == createdName then already = true break end
          end
          if not already then
            rayPickMaterialNameList[#rayPickMaterialNameList + 1] = createdName
          end
        end
        getMaterials()
        selectMaterialByName(createdName)
        ffi.copy(newMatName, "")
        ffi.copy(newMatMapTo, "")
        v.dirtyMaterials[currentMaterial:getField('name', 0)] = true
      end
    end
    if createMaterialError then im.EndDisabled() end
    im.SameLine()
    if im.Button("Cancel") then
      editor.hideWindow(createMaterialWindowName)
    end
  end

  if createMaterialMessage and createMaterialMessage ~= "" and createMaterialError then
    im.SetCursorPos(im.ImVec2(im.GetCursorPosX(), im.GetContentRegionAvail().y + im.GetCursorPosY() - im.GetTextLineHeight()))
    im.TextColored(im.ImVec4(1, 1, 0, 1), createMaterialMessage)
  end
  editor.endWindow()
end

local function materialPreviewWindowGui()
  if editor.beginWindow(materialPreviewWindowName, "Material Preview##Window") then
    if not v.style then v.style = im.GetStyle() end
    local availableSize = im.GetContentRegionAvail()
    availableSize.y = availableSize.y - 28
    local size = (availableSize.x < availableSize.y) and availableSize.x or availableSize.y
    size = (size < 64 and 64 or size)

    if previewMeshes then
      im.TextUnformatted("Preview Meshes")
      im.ShowHelpMarker("RMB: Orbit view\nScroll Wheel (+ Ctrl): Zoom view\nShift + RMB: Move sun" , true)
      im.SameLine()
      im.PushItemWidth(size - (im.CalcTextSize("Preview Meshes(?)").x + 3 * v.style.ItemSpacing.x + 24))
      if im.Combo1("##MaterialPreviewMeshCombo", previewMeshIndex, previewMeshNamesPtr) then
        updateExtMaterialPreviewMesh()
      end
      im.SameLine()
      if editor.uiIconImageButton(editor.icons.refresh, im.ImVec2(24, 24)) then
        getPreviewMeshes()
      end
      im.tooltip("Refresh Preview Mesh List\n\nThe tool fetches all dae files from `\\art\\shapes\\material_preview`")
      im.PopItemWidth()
    end

    materialPreview(size)
  end
  editor.endWindow()
end

local function onEditorGui()
  materialPreviewWindowGui()
  materialUsageWindowGui()

  if focusWindow == true then
    im.SetNextWindowFocus()
    focusWindow = false
  end

  if editor.beginWindow(toolWindowName, "Material Editor") then
    v.style = im.GetStyle()
    v.inputWidgetHeight = 16 + v.style.FramePadding.y
    menuGui()

    if openPickMapToFromObjectPopup == true then
      local popupHeight = im.uiscale[0] * (#pickingFromObjectMaterials * v.inputWidgetHeight + v.style.WindowPadding.y)
      pickMapToFromObjectPopupHeight = popupHeight > pickMapToFromObjectPopupMaxHeight * im.uiscale[0] and pickMapToFromObjectPopupMaxHeight * im.uiscale[0] or popupHeight
      im.OpenPopup("PickMapToFromObjectPopup")
      openPickMapToFromObjectPopup = false
    end

    pickFromTSStaticGui()

    if im.BeginChild1("MATERIAL_EDITOR_MAIN") then

      if editor.uiInputSearchTextFilter("Filter materials (inc, -exc)", matFilter, im.GetContentRegionAvailWidth()) then
        v.currentMaterialIndex = 0
        getMaterials()
      end

      if not v.materialNamesPtr or not v.materialNameList then
        im.EndChild()
        editor.endWindow()
        return
      end

      -- Set width of the Combo widget. The width dpends on whether there're dirty materials or not,
      -- so whether we have display additional buttons next to the combo widget or not.
      im.PushItemWidth(
        next(v.dirtyMaterials) == nil and
        (im.GetContentRegionAvailWidth() - (math.ceil(17 * im.uiscale[0]) + 2 * v.style.FramePadding.y + v.style.ItemSpacing.x))
        or
        (im.GetContentRegionAvailWidth() - (2 * (math.ceil(17 * im.uiscale[0]) + 2 * v.style.FramePadding.y) + 2 * v.style.ItemSpacing.x))
      )
      if v.materialNamesPtrCount == 0 then im.BeginDisabled() end
      if im.Combo1("##Materials", editor.getTempInt_NumberNumber(v.currentMaterialIndex), v.materialNamesPtr, (#v.materialNameList + 1), 20) then
        if dbg then editor.logInfo(logTag .. "Material has changed!") end
        v.currentMaterialIndex = editor.getTempInt_NumberNumber()
        updateMaterialProperties()
        local levelMaterialNames = editor.getPreference("materialEditor.general.levelMaterialNames")
        levelMaterialNames[getMissionPath()] = v.materialNameList[v.currentMaterialIndex]
        editor.setPreference("materialEditor.general.levelMaterialNames", levelMaterialNames)
      end
      if v.materialNamesPtrCount == 0 then
        im.EndDisabled()
        if not v.materialListIsNothingFound then
          im.SameLine()
          editor.uiIconImageButton(editor.icons.warning, im.ImVec2(v.inputWidgetHeight, v.inputWidgetHeight), editor.color.warning.Value)
          im.tooltip("The selected object either has no materials assigned to it or all the materials were auto-generated and can't be changed using the material editor.")
        end
      end
      im.PopItemWidth()
      if currentMaterial and v.dirtyMaterials and v.dirtyMaterials[currentMaterial:getField("name", 0)] then
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.material_save_current, im.ImVec2(v.inputWidgetHeight, v.inputWidgetHeight)) then
          scanTextureIssues(currentMaterial)

          if hasTextureErrors() then
            im.OpenPopup("SaveCurrentMaterialTextureErrors")
          else
            saveCurrentMaterial()
          end
        end
        im.tooltip("Save current material")

        if im.BeginPopup("SaveCurrentMaterialTextureErrors") then
          im.TextColored(editor.color.warning.Value, "This material has errors that will impact performance significantly.")
          im.TextUnformatted("Do you still want to save it?")

          im.Separator()

          if im.Button("Save anyway") then
            saveCurrentMaterial()
            im.CloseCurrentPopup()
          end

          im.SameLine()

          if im.Button("Cancel") then
            im.CloseCurrentPopup()
          end

          im.EndPopup()
        end
      end

      if next(v.dirtyMaterials) then
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.material_save_all, im.ImVec2(v.inputWidgetHeight, v.inputWidgetHeight)) then
          local anyErrors = false

          for matName, _ in pairs(v.dirtyMaterials) do
            local mat = scenetree.findObject(matName)
            if mat then
              scanTextureIssues(mat)
              if hasTextureErrors() then
          anyErrors = true
          break
              end
            end
          end

          if anyErrors then
            im.OpenPopup("SaveAllMaterialsTextureErrors")
          else
            saveAllDirtyMaterials()
          end
        end

        if im.IsItemHovered() then
          im.BeginTooltip()
          local tooltipMsg = "Save all dirty materials:\n"
          for k, _ in pairs(v.dirtyMaterials) do
            tooltipMsg = tooltipMsg .. "* " .. k .. "\n"
          end
          im.TextUnformatted(tooltipMsg)
          im.EndTooltip()
        end

        if im.BeginPopup("SaveAllMaterialsTextureErrors") then
          im.TextColored(editor.color.warning.Value, "One or more materials have errors that will lead to performance issues.")
          im.TextUnformatted("Do you still want to save all dirty materials?")

          im.Separator()

          if im.Button("Save all anyway") then
            saveAllDirtyMaterials()
            im.CloseCurrentPopup()
          end

          im.SameLine()

          if im.Button("Cancel") then
            im.CloseCurrentPopup()
          end

          im.EndPopup()
        end
      end

      drawGui()
    end
    im.EndChild()

  end
  editor.endWindow()

  if editor.isWindowVisible(toolWindowName) then
    createMaterialWindowGui()
    materialsByTagWindowGui()
  end
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
  editor.hideWindow(createMaterialWindowName)

  if not loadedAllVehicleMaterials then
    loadedAllVehicleMaterials = true
    -- load all vehicle materials too
    editor.logInfo("Loading all vehicles materials...")
    loadDirRec("vehicles/")
    --TODO: load all level materials too, assets folder too etc.
    editor.logInfo("Gathering tags from materials...")
    core_jobsystem.create(mapTagsJob, 1)
  end
end

local function onVehicleSwitched(oid, nid, player)
  --TODO: need more investigation on reload scripts the editor is not yet created, while vehicle is switched
  if editor and editor.isWindowVisible and editor.active and editor.isWindowVisible(toolWindowName) == true and oid ~= nid then
    core_jobsystem.create(mapTagsJob, 1)
    getMaterials()
    updateMaterialProperties()
  end
end

local function onFilesChanged(files)
  for _,v in pairs(files) do
    local path = v.filename
    local levelName, levelFilepath = string.match(path, "/levels/([%w_]+)(.+)")
    local artFilepath = string.match(path, "/art/(.+)")
    if levelName or artFilepath then
      local filename = string.match(path, "[^/]*$")
      if filename == "main.materials.json" then
        getMaterials()
        return
      end
    end
  end
end

local function onEditorPreferenceValueChanged(path, value)
  if path == "materialEditor.general.thumbnailSize" then
    options.thumbnailSize = value
    updateMaterialPreviewRender = true
  end
  if path == "materialEditor.general.maxMaterialPreviewSize" then
    options.maxMaterialPreviewSize = value
    updateMaterialPreviewRender = true
  end
  if path == "materialEditor.general.textFilterResultsWithSameFirstCharAtTop" then
    options.textFilterResultsWithSameFirstCharAtTop = value
    getMaterials()
  end
end

local function onEditorRegisterPreferences(prefsRegistry)
  prefsRegistry:registerCategory("materialEditor")
  prefsRegistry:registerSubCategory("materialEditor", "general", nil,
  {
    -- {name = {type, default value, desc, label (nil for auto Sentence Case), min, max, hidden, advanced, customUiFunc, enumLabels}}
    {thumbnailSize = {"int", 64, "", nil, 32, 256 }},
    {maxMaterialPreviewSize = {"int", 256, "", nil, 64, 1024}},
    {textFilterResultsWithSameFirstCharAtTop = {"bool", true, "List materials starting with the same chars as the text filter at top of materials list."}},
    -- hidden
    {columnSizes = {"table", {29, 53, 300, 145, 97, 280}, "", nil, nil, nil, true}},
    {levelMaterialNames = {"table", {}, "", nil, nil, nil, true}},
  })
end

local function onEditorActivated()
  rayPickMaterialNameList = nil
  pickMaterialsFromObjectName = nil
  getMaterials()
  getGroundmodels()
  getPreviewMeshes()

  matPreview:setObjectModel("/art/shapes/material_preview/cube_1m.dae")
  matPreview:setRenderState(false,false,false,false,false,false)
  matPreview:setCamRotation(0.6, 3.9)
  matPreview:setSunRotation(135,90)
  matPreview:fitToShape()
  matPreview:setZoom(1.4)
  matPreview:renderWorld(dimRdr)

  extMatPreview:setObjectModel("/art/shapes/material_preview/cube_1m.dae")
  extMatPreview:setRenderState(false,false,false,false,false,false)
  extMatPreview:setCamRotation(0.6, 3.9)
  extMatPreview:setSunRotation(135,90)
  extMatPreview:fitToShape()
  extMatPreview:setZoom(1.4)
  extMatPreview:renderWorld(dimRdr)

  levelPath = getMissionPath()
  lastPath = levelPath
  lastCreateMaterialPath = (FS:directoryExists(levelPath .. "art/") and (levelPath .. "art/") or levelPath)

  updateMaterialProperties()
end

local function onEditorDeactivated()
  v.materialNameList = nil
  v.materialNamesPtr = nil

  previewMeshes = nil
  groundModels = nil
  -- tags = nil
end

local function onEditorInitialized()
  editor.addWindowMenuItem("Material Editor", onWindowMenuItem, nil, true)
  editor.registerWindow(toolWindowName, im.ImVec2(310, 580))
  editor.registerWindow(createMaterialWindowName, im.ImVec2(450, 150))
  editor.registerWindow(materialPreviewWindowName, im.ImVec2(300, 300))
  editor.registerWindow(materialsByTagsWindowName, im.ImVec2(260, 320))
  editor.registerWindow(materialUsageWindowName, im.ImVec2(420, 340))
  editor.hideWindow(materialUsageWindowName)
  editor.hideWindow(createMaterialWindowName)
  editor.hideWindow(materialPreviewWindowName)
  editor.hideWindow(materialsByTagsWindowName)
  core_jobsystem.create(mapTagsJob, 1)
end

local function onEditorObjectSelectionChanged()
end

local function onEditorDeleteSelection()
end

M.dbg = dbg
M.setProperty = setProperty
M.deleteMapButton = deleteMapButton
M.v = v
M.o = o
M.customMaterialsArray = customMaterialsArray
M.customMaterialsArrayPtr = customMaterialsArrayPtr

M.imageButton = imageButton
M.inputFloat = inputFloat
M.colorEdit4 = colorEdit4

M.onFilesChanged = onFilesChanged
M.onVehicleSwitched = onVehicleSwitched

M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized
M.onEditorActivated = onEditorActivated
M.onEditorDeactivated = onEditorDeactivated

M.showMaterialEditor = showMaterialEditor
M.selectMaterialByName = selectMaterialByName
M.setMaterialDirty = setMaterialDirty

M.onEditorObjectSelectionChanged = onEditorObjectSelectionChanged
M.onEditorRegisterPreferences = onEditorRegisterPreferences
M.onEditorPreferenceValueChanged = onEditorPreferenceValueChanged
M.onEditorDeleteSelection = onEditorDeleteSelection

return M
