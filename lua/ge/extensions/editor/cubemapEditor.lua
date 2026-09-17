-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local ffi = require('ffi')
local M = {}
local im = ui_imgui

local toolWindowName = "cubemapEditor"

local cubemaps = nil
local selectedCubemapObj = nil
local cubemapNamePtr = im.ArrayChar(128)
local cubemapFaceThumbnailSize = 128
local cubemapDirty = {}

local captureResolution = im.IntPtr(256)
local normalizeCubemap = im.BoolPtr(false)

local cubemapBaseDir = im.ArrayChar(512)     -- base folder like /levels/<lvl>/art/cubemaps/
local exportMatName  = im.ArrayChar(128)     -- material datablock name (dummy material) to export/update
local statusById = {}                        -- per-cubemap message
local onSelectCubemapCb = nil                -- integration callback

local function ensureTrailingSlash(p)
  if not p or p == "" then return "" end
  return string.endswith(p, "/") and p or (p .. "/")
end

local function normalizeDirPath(p)
  if not p or p == "" then return "" end
  p = ensureTrailingSlash(p)
  if string.startswith(p, "/") then return p end
  if FS:directoryExists("/" .. p) then return "/" .. p end
  return p
end

local function normalizeFilePath(p)
  if not p or p == "" then return "" end
  if string.startswith(p, "/") then return p end
  if FS:fileExists("/" .. p) then return "/" .. p end
  return p
end

local function sanitizeName(n)
  if not n then return "" end
  n = n:gsub("%s+", "")
  n = n:gsub("[^%w_%-%.]", "")
  return n
end

local function resolvePath(res)
  if not res then return nil end
  local p = res
  if not string.startswith(p or '', '/') and FS:fileExists('/'..(p or '')) then
    p = '/'..p
  end
  return p
end

local function getSelectedCubemapFilename()
  if not selectedCubemapObj or not selectedCubemapObj.getFilename then return "" end
  local fn = selectedCubemapObj:getFilename() or ""
  fn = resolvePath(fn) or fn
  return fn or ""
end

local function getDatablockNames()
  local ui = sanitizeName(ffi.string(cubemapNamePtr) or "")
  local obj = selectedCubemapObj and sanitizeName(selectedCubemapObj:getName()) or ""
  local base = (ui ~= "" and ui) or (obj ~= "" and obj) or "cubemap"

  if string.endswith(base, "_reflection") then
    local mat = base:sub(1, #base - #"_reflection")
    if mat == "" then mat = base end
    return base, mat
  end
  return base .. "_reflection", base
end

local function findCubemapMaterial(jsonTbl, cubemapDataName)
  if not jsonTbl or type(jsonTbl) ~= "table" then return nil end
  for key, block in pairs(jsonTbl) do
    if type(block) == "table" and block.class == "Material" and block.cubemap == cubemapDataName then
      return (block.name and block.name ~= "" and block.name) or key
    end
  end
  return nil
end

local function setStatus(msg)
  if not selectedCubemapObj then return end
  statusById[selectedCubemapObj:getId()] = msg
end

local function computeDefaultBaseDir()
  local fn = getSelectedCubemapFilename()
  if fn ~= "" then
    local dir, filename, ext = path.split(fn)
    local base = dir
    if base ~= "" then
      base = normalizeDirPath(base)
      if FS:directoryExists(base) then return base end
    end
  end
  local lvl = normalizeDirPath(getMissionPath() or "/")
  local cubemapDataName, defaultMatName = getDatablockNames()
  return lvl .. "art/cubemaps/" .. cubemapDataName
end

local function computeDefaultExportMatName()
  local cubemapDataName, defaultMatName = getDatablockNames()
  local fn = getSelectedCubemapFilename()
  if fn ~= "" and FS:fileExists(fn) then
    local t = jsonReadFile(fn)
    if t and type(t) == "table" then
      local found = findCubemapMaterial(t, cubemapDataName)
      if found and found ~= "" then
        return found
      end
    end
  end
  return defaultMatName
end

local function boolFromValue(v)
  if v == true then return true end
  if v == false or v == nil then return false end

  if type(v) == "number" then
    return v ~= 0
  end

  if type(v) == "string" then
    local s = v:lower()
    return s == "true" or s == "1" or s == "yes"
  end

  return false
end

local function computeDefaultNormalize()
  if not selectedCubemapObj then return false end

  if selectedCubemapObj.getField then
    local v = selectedCubemapObj:getField("normalize", 0)
    if v ~= nil and v ~= "" then
      return boolFromValue(v)
    end
  end

  if selectedCubemapObj.normalize ~= nil then
    return boolFromValue(selectedCubemapObj.normalize)
  end

  local cubemapDataName = getDatablockNames()
  local fn = getSelectedCubemapFilename()

  if fn ~= "" and FS:fileExists(fn) then
    local t = jsonReadFile(fn)
    if t and type(t) == "table" then
      local block = t[cubemapDataName]
      if type(block) == "table" and block.normalize ~= nil then
        return boolFromValue(block.normalize)
      end
    end
  end

  return false
end

local function syncDefaultsFromSelected()
  if not selectedCubemapObj then return end

  local bd = computeDefaultBaseDir()
  ffi.copy(cubemapBaseDir, bd)

  local mn = computeDefaultExportMatName()
  ffi.copy(exportMatName, mn)
  normalizeCubemap[0] = computeDefaultNormalize()
end

local function stringToVec3(s)
  if type(s) ~= "string" then return nil end
  local x, y, z = s:match("^%s*([%-%d%.eE]+)%s*,%s*([%-%d%.eE]+)%s*,%s*([%-%d%.eE]+)%s*$")
  if not x then return nil end
  return vec3(tonumber(x), tonumber(y), tonumber(z))
end

local function getCapturePath()
  local baseDir = normalizeDirPath(ffi.string(cubemapBaseDir) or "")
  if baseDir == "" then baseDir = computeDefaultBaseDir() end
  return baseDir .. "cubemap/skybox"
end

local function refreshCubemaps()
  cubemaps = scenetree.findClassObjects("CubemapData")
end

local function selectCubemap(cubemapIndex)
  if not cubemaps or #cubemaps == 0 then
    selectedCubemapObj = nil
    ffi.copy(cubemapNamePtr, "")
    return
  end

  local listName = cubemaps[cubemapIndex or 1] or cubemaps[1]
  selectedCubemapObj = scenetree.findObject(listName)

  local shownName = listName
  if selectedCubemapObj and selectedCubemapObj.getName then
    shownName = selectedCubemapObj:getName() or listName
  end
  ffi.copy(cubemapNamePtr, tostring(shownName))

  syncDefaultsFromSelected()
end

local function selectCubemapByName(name)
  if not cubemaps then refreshCubemaps() end
  if not cubemaps or #cubemaps == 0 then
    selectCubemap(1)
    return
  end
  if not name or name == "" then
    selectCubemap(1)
    return
  end
  for idx, n in ipairs(cubemaps) do
    if n == name then
      selectCubemap(idx)
      return
    end
  end
  selectCubemap(1)
end

local function cubemapFaceUndo(actionData)
  local obj = scenetree.findObject(actionData.objectId)
  if obj then
    obj:setField(actionData.property, actionData.layer, actionData.oldValue)
  end
end

local function cubemapFaceRedo(actionData)
  local obj = scenetree.findObject(actionData.objectId)
  if obj then
    obj:setField(actionData.property, actionData.layer, actionData.newValue)
  end
end

local function dragDropTargetCubemapFace(index)
  if im.BeginDragDropTarget() then
    local payload = im.AcceptDragDropPayload("ASSETDRAGDROP")
    if payload ~= nil then
      assert(payload.DataSize == 2048)
      local data = ffi.string(payload.Data)
      local oldValue = selectedCubemapObj:getField("cubeFace", index)
      if oldValue ~= data then
        editor.history:commitAction(
          "SetCubeMapFace_" .. tostring(index),
          {
            objectId = selectedCubemapObj:getId(),
            property = "cubeFace",
            layer = index,
            newValue = data,
            oldValue = oldValue
          },
          cubemapFaceUndo,
          cubemapFaceRedo
        )
        cubemapDirty[selectedCubemapObj:getId()] = true
      end
    end
    im.EndDragDropTarget()
  end
end

local function cubemapFaceImageButton(index, tooltip)
  im.PushID1("cubeFace" .. tostring(index))
  local facePath = selectedCubemapObj:getField("cubeFace", index)
  local tex = editor.getTempTextureObj(facePath)

  if im.ImageButton(
    "##imageButton2",
    tex.texId,
    im.ImVec2(cubemapFaceThumbnailSize, cubemapFaceThumbnailSize),
    im.ImVec2Zero,
    im.ImVec2One,
    im.ImColorByRGB(255,255,255,255).Value,
    im.ImColorByRGB(255,255,255,255).Value
  ) then
    editor_fileDialog.openFile(
      function(data)
        local oldValue = selectedCubemapObj:getField("cubeFace", index)
        if oldValue ~= data.filepath then
          editor.history:commitAction(
            "SetCubeMapFace_" .. tostring(index),
            {
              objectId = selectedCubemapObj:getId(),
              property = "cubeFace",
              layer = index,
              newValue = data.filepath,
              oldValue = oldValue
            },
            cubemapFaceUndo,
            cubemapFaceRedo
          )
          cubemapDirty[selectedCubemapObj:getId()] = true
        end
      end,
      {{"Any files", "*"},{"Images",{".png", ".dds", ".jpg"}},{"DDS",".dds"},{"PNG",".png"},{"JPG",".jpg"}},
      false,
      path.splitWithoutExt(facePath),
      true
    )
  end

  im.PopID()
  dragDropTargetCubemapFace(index)

  if tooltip then
    im.tooltip(tooltip .. "\n" .. tostring(facePath))
  else
    im.tooltip(tostring(facePath))
  end
end

local function assignCapturedFaces(prefix)
  if not selectedCubemapObj then return false end

  for i = 0, 5 do
    local facePath = prefix .. tostring(i) .. ".hdr.dds"
    local rp = normalizeFilePath(facePath)
    if not FS:fileExists(rp) then
      setStatus("Error: missing " .. tostring(facePath))
      return false
    end
    selectedCubemapObj:setField("cubeFace", i, rp)
  end
  local p = core_camera.getPosition()
  selectedCubemapObj.captureLocation = string.format("%.6f,%.6f,%.6f", p.x, p.y, p.z)
  cubemapDirty[selectedCubemapObj:getId()] = true
  setStatus("Captured and assigned faces.")
  return true
end

local function captureAndAssign(resolution)
  if not selectedCubemapObj then return end

  resolution = tonumber(resolution) or 256

  if resolution < 128 then resolution = 128 end
  if resolution > 2048 then resolution = 2048 end

  local baseDir = normalizeDirPath(ffi.string(cubemapBaseDir) or "")
  if baseDir == "" then baseDir = computeDefaultBaseDir() end
  if baseDir == "" then
    setStatus("Invalid base directory: " .. tostring(baseDir))
    return
  end
  if not FS:directoryExists(baseDir) then
    local ok = FS:directoryCreate(baseDir, true)
    if not ok or not FS:directoryExists(baseDir) then
      setStatus("Failed to create base directory: " .. tostring(baseDir))
      return
    end
  end

  local prefix = getCapturePath()
  local outDir = prefix:match("^(.*)/[^/]*$") or ""
  outDir = normalizeDirPath(outDir)
  if outDir ~= "" and not FS:directoryExists(outDir) then
    FS:directoryCreate(outDir, true)
  end

  captureCameraCubemap(prefix, resolution)
  assignCapturedFaces(prefix)
end

local function removeCubemapFromJson()
  if not selectedCubemapObj then return false end
  local cubemapDataName = getDatablockNames()

  local fn = selectedCubemapObj.getFilename and (selectedCubemapObj:getFilename() or "") or ""
  fn = resolvePath(fn) or fn

  if not fn or fn == "" then
    local baseDir = normalizeDirPath(ffi.string(cubemapBaseDir) or "")
    if baseDir == "" then baseDir = computeDefaultBaseDir() end
    local folder = normalizeDirPath(baseDir .. "/")
    fn = folder .. "main.materials.json"
  end

  fn = resolvePath(fn) or fn
  if not fn or fn == "" then
    local msg = "No json file path."
    setStatus(msg)
    return false
  end
  if not FS:fileExists(fn) then
    local msg = "Json file not found: " .. tostring(fn)
    setStatus(msg)
    return false
  end

  local t = jsonReadFile(fn)
  if not t or type(t) ~= "table" then
    local msg = "Invalid json: " .. tostring(fn)
    setStatus(msg)
    return false
  end

  local removedAny = false

  if t[cubemapDataName] ~= nil then
    t[cubemapDataName] = nil
    removedAny = true
  end

  for k, block in pairs(t) do
    if type(block) == "table" and block.class == "Material" and block.cubemap == cubemapDataName then
      t[k] = nil
      removedAny = true
    end
  end

  local msg
  if removedAny then
    jsonWriteFile(fn, t, true)
    msg = "Removed json entries from: " .. tostring(fn)
    setStatus(msg)
    return true
  else
    msg = "No entries found to remove in: " .. tostring(fn)
    setStatus(msg)
    return false
  end
end

local function exportJson()
  if not selectedCubemapObj then return false end

  local cubemapDataName, defaultMatName = getDatablockNames()

  local outFile = nil
  local fn = selectedCubemapObj.getFilename and selectedCubemapObj:getFilename() or ""
  if fn and fn ~= "" then
    outFile = resolvePath(fn) or fn
  end

  if not outFile or outFile == "" then
    local baseDir = normalizeDirPath(ffi.string(cubemapBaseDir) or "")
    if baseDir == "" then baseDir = computeDefaultBaseDir() end
    local folder = normalizeDirPath(baseDir .. "/")
    if not FS:directoryExists(folder) then FS:directoryCreate(folder, true) end
    outFile = folder .. "main.materials.json"
  end

  local existing = nil
  if FS:fileExists(outFile) then
    existing = jsonReadFile(outFile)
    if existing ~= nil and type(existing) ~= "table" then existing = nil end
  end

  local matName = sanitizeName(ffi.string(exportMatName) or "")
  if matName == "" then
    matName = defaultMatName
    local found = findCubemapMaterial(existing, cubemapDataName)
    if found and found ~= "" then matName = found end
  end

  local faces = {}
  for i = 0, 5 do faces[i+1] = selectedCubemapObj:getField("cubeFace", i) or "" end

  local captureLocation = selectedCubemapObj.captureLocation or nil

  local data = existing or {}
  local cubemapJson = {
    name = cubemapDataName,
    class = "CubemapData",
    cubeFace = faces,
    captureLocation = captureLocation
  }

  if normalizeCubemap[0] then
    cubemapJson.normalize = true
  end

  data[cubemapDataName] = cubemapJson
  data[matName] = {
    name = matName,
    mapTo = "unmapped_mat",
    class = "Material",
    Stages = { {}, {}, {}, {} },
    cubemap = cubemapDataName
  }

  jsonWriteFile(outFile, data, true)
  setStatus("Saved: " .. tostring(outFile))
  return true
end

local function saveCubemap()
  if not selectedCubemapObj then return end
  local prevName = selectedCubemapObj:getName()

  local newName = sanitizeName(ffi.string(cubemapNamePtr) or "")
  if newName ~= "" then
    selectedCubemapObj:setName(newName)
  end

  selectedCubemapObj:setField("normalize", 0, normalizeCubemap[0] and "1" or "0")

  if scenetree.matLuaEd_PersistMan then
    scenetree.matLuaEd_PersistMan:setDirty(selectedCubemapObj, "")
    scenetree.matLuaEd_PersistMan:saveDirtyObject(selectedCubemapObj)
  end

  syncDefaultsFromSelected()

  exportJson()

  refreshCubemaps()
  selectCubemapByName(newName ~= "" and newName or prevName)
  if not selectedCubemapObj then
    selectCubemap(1)
  end
  cubemapDirty[selectedCubemapObj:getId()] = nil
end

local function newCubemap()
  local baseName = "cubemap_new"
  local suffix = "_reflection"
  local name = baseName .. suffix
  local i = 1
  while scenetree.findObject(name) do
    name = baseName .. tostring(i) .. suffix
    i = i + 1
  end
  local newObj = editor.createCustomClassObject("CubemapData")
  if newObj then
    newObj.name = name
    newObj.canSave = false
    refreshCubemaps()
    selectedCubemapObj = newObj
    ffi.copy(cubemapNamePtr, newObj:getName())
    ffi.copy(cubemapBaseDir, "")
    ffi.copy(exportMatName, "")
    syncDefaultsFromSelected()
  end
  cubemapDirty[selectedCubemapObj:getId()] = true
end

local function deleteCubemap()
  if not selectedCubemapObj then return end
  local parent = selectedCubemapObj:getGroup()
  if parent then
    parent:removeObject(selectedCubemapObj)
  end
  removeCubemapFromJson()
  refreshCubemaps()
  selectCubemap(1)
  cubemapDirty[selectedCubemapObj:getId()] = nil
  selectedCubemapObj:delete()
  selectedCubemapObj = nil
end

local lastName = nil
local lastBaseDir = nil
local lastMatname = nil

local function drawWindow()
  if editor.beginWindow(toolWindowName, "Create Cubemap") then
    if not cubemaps then
      refreshCubemaps()
      selectCubemap(1)
    end

    im.Columns(2, "CreateCubemapColumn")
    im.SameLine()
    if selectedCubemapObj and cubemapDirty[selectedCubemapObj:getId()] == true then
      if im.SmallButton("Save") then saveCubemap() end
      if im.IsItemHovered() then im.SetTooltip("Save modifications of selected Cubemap") end
      im.SameLine()
    end

    if im.SmallButton("New") then newCubemap() end
    if im.IsItemHovered() then im.SetTooltip("Create a new Cubemap under selected SceneTree group") end

    im.SameLine()
    if im.SmallButton("Delete") then deleteCubemap() end
    if im.IsItemHovered() then im.SetTooltip("Delete selected Cubemap") end

    if im.BeginChild1("CreateCubemapsLeftChild", nil, true) then
      for index, cubemap in ipairs(cubemaps or {}) do
        if selectedCubemapObj then
          im.PushStyleColor2(
            im.Col_Button,
            (selectedCubemapObj:getName() == cubemap) and im.GetStyleColorVec4(im.Col_ButtonActive) or im.ImVec4(1,1,1,0)
          )
        end
        im.PushItemWidth(im.GetContentRegionAvailWidth() - 10)
        if im.Button(cubemap) then
          selectCubemap(index)
        end
        im.PopItemWidth()
        if selectedCubemapObj then im.PopStyleColor() end
      end
    end
    im.EndChild()
    if selectedCubemapObj then
      im.NextColumn()

      im.TextUnformatted("Cubemap Name:")
      im.SameLine()
      im.InputText("##cubemapName", cubemapNamePtr, nil, im.flags(im.InputTextFlags_CharsNoBlank))

      local cubemapName = sanitizeName(ffi.string(cubemapNamePtr))
      if cubemapName ~= lastName and selectedCubemapObj then
        selectedCubemapObj.name = sanitizeName(ffi.string(cubemapNamePtr) or "")
        syncDefaultsFromSelected()
        refreshCubemaps()
        cubemapDirty[selectedCubemapObj:getId()] = true
      end
      lastName = selectedCubemapObj.name

      cubemapFaceThumbnailSize = (im.GetContentRegionAvailWidth() - (3 * im.GetStyle().ItemSpacing.x) - 8) / 4

      -- -Y Back[2]
      im.SetCursorPosX(im.GetCursorPosX() + cubemapFaceThumbnailSize + im.GetStyle().ItemSpacing.x + 2)
      cubemapFaceImageButton(2, "-Y Back[2]")

      -- -X Left[1] / +Z Top[4] / +X Right[0] / -Z Bottom[5]
      cubemapFaceImageButton(1, "-X Left[1]")
      im.SameLine()
      cubemapFaceImageButton(4, "+Z Top[4]")
      im.SameLine()
      cubemapFaceImageButton(0, "+X Right[0]")
      im.SameLine()
      cubemapFaceImageButton(5, "-Z Bottom[5]")

      -- +Y Front[3]
      im.SetCursorPosX(im.GetCursorPosX() + cubemapFaceThumbnailSize + im.GetStyle().ItemSpacing.x + 2)
      cubemapFaceImageButton(3, "+Y Front[3]")

      im.TextUnformatted("Base directory:")
      im.PushItemWidth(im.GetContentRegionAvailWidth() - (im.CalcTextSize("...").x + 2 * im.GetStyle().FramePadding.x + im.GetStyle().ItemSpacing.x))
      im.InputText("##cm_baseDir", cubemapBaseDir)
      im.PopItemWidth()
      im.SameLine()

      if im.Button("...##cm_pickBaseDir") then
        editor_fileDialog.openFile(function(data)
          local d = data.path or data.filepath or ""
          ffi.copy(cubemapBaseDir, normalizeDirPath(d))
          end,nil,true,"/", nil,nil)
      end

      local baseDirName = ffi.string(cubemapBaseDir)
      if baseDirName ~= lastBaseDir and selectedCubemapObj then
        cubemapDirty[selectedCubemapObj:getId()] = true
      end
      lastBaseDir = baseDirName

      im.TextUnformatted("Cubemap material name:")
      im.PushItemWidth(im.GetContentRegionAvailWidth() - 10)
      im.InputText("##cm_exportMatName", exportMatName, nil, im.flags(im.InputTextFlags_CharsNoBlank))
      im.PopItemWidth()
      local baseMatName = ffi.string(exportMatName)
      if baseMatName ~= lastMatname and selectedCubemapObj then
        cubemapDirty[selectedCubemapObj:getId()] = true
      end
      lastMatname = baseMatName

      if im.Checkbox("Normalize cubemap##cm_normalize", normalizeCubemap) then
        cubemapDirty[selectedCubemapObj:getId()] = true
      end
      im.tooltip('When enabled, cubemap will be normalized to ambient.')

      local prefix = getCapturePath()
      im.TextUnformatted("Capture path:")
      im.TextColored(im.ImVec4(0.8, 0.8, 0.8, 1), prefix..'*.hdr.dds')

      if im.Button("Capture and Assign##cm_capAssign") then
        captureAndAssign(captureResolution[0])
      end
      im.tooltip("Cubemap is captured from camera location, it will overwrite current cubemap faces.")

      im.SameLine()

      local expMin, expMax = 7, 11
      local curExp = math.floor(math.log(captureResolution[0]) / math.log(2) + 0.5)
      if curExp < expMin then curExp = expMin end
      if curExp > expMax then curExp = expMax end

      local expPtr = im.IntPtr(curExp)
      im.PushItemWidth(160)
      if im.SliderInt("Resolution: ##cm_capRes", expPtr, expMin, expMax, "") then
        captureResolution[0] = bit.lshift(1, expPtr[0]) -- 2^exp
      end
      im.PopItemWidth()
      im.SameLine()
      im.TextUnformatted(tostring(captureResolution[0])..'px')

      local pos = stringToVec3(selectedCubemapObj.captureLocation)
      if pos then
        im.SameLine()
        if im.Button("Go to cubemap location##cm_location") then
          core_camera.setPosition(0, pos)
        end
      end
      local msg = statusById[selectedCubemapObj:getId()]
      if msg and msg ~= "" then
        im.TextColored(editor.color.warning.Value, msg)
      end

      if onSelectCubemapCb then
        if im.Button("Select") then
          onSelectCubemapCb(selectedCubemapObj:getName())
          editor.hideWindow(toolWindowName)
        end
        im.SameLine()
        if im.Button("Cancel") then
          editor.hideWindow(toolWindowName)
        end
      end
      im.Columns(1)
    end
  end
  editor.endWindow()
end

local function show(onSelectCb, preselectName)
  onSelectCubemapCb = onSelectCb
  if not cubemaps then refreshCubemaps() end
  if preselectName and preselectName ~= "" then
    selectCubemapByName(preselectName)
  else
    if not selectedCubemapObj then selectCubemap(1) end
  end
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  editor.registerWindow(toolWindowName, im.ImVec2(750, 380))
  editor.hideWindow(toolWindowName)
  editor.addWindowMenuItem("Cubemap Editor", function() M.show() end, nil, false)
end

local function onEditorGui()
  drawWindow()
end

M.show = show
M.onEditorInitialized = onEditorInitialized
M.onEditorGui = onEditorGui

return M
