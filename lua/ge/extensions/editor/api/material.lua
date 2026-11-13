-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local editor

-- Creates a new material object with given params and writes it to disk.
-- param 'materialName'; type 'string';
-- param 'materialFilename'; type 'string';
-- param 'materialMapTo'; type 'number';
-- returns; type 'bool';
local function createMaterial(materialName, materialFilename, materialMapTo)
  -- Check if new materialName is empty or a material with the gievn name already exists.
  if #materialName == 0 then
    log('E', logTag, 'Material name must not be empty!')
    editor.showNotification("Material name must not be empty!")
    return false
  end

  -- Check if a material with the given name exists already
  if scenetree.findObject(materialName) then
    log('E', logTag, "A material with the given name '" .. materialName .. "' already exists!")
    return false
  end

  -- Check if directory exists.
  local directory,_,_ = path.split(materialFilename)
  if FS:directoryExists(directory) == false then
    log('E', logTag, "Given directory '" .. directory .."' does not exist!")
    editor.showNotification("Given directory '" .. directory .."' does not exist!")
    return false
  end

  if #materialMapTo == 0 then
    log('W', "", "No 'mapTo' value given. Using material name instead.")
    editor.showNotification("No 'mapTo' value given. Using material name instead.")
    materialMapTo = materialName
  end

  local mat = createObject('Material')
  mat:setFilename(materialFilename)
  mat:setField('name', 0, materialName)
  mat:setField('mapTo', 0, materialMapTo)
  mat:setField('version', 0, '1.5')
  mat:setField('cubemap', 0, "")
  mat:setField('dynamicCubemap', 0, "1")
  mat.canSave = true
  mat:registerObject(materialName)
  scenetree.matLuaEd_PersistMan:setDirty(mat, '')
  scenetree.matLuaEd_PersistMan:saveDirty()
  return true
end

-- Sets a property of a material.
-- param 'material'; type 'class<Material>' || 'string';
-- param 'property'; type 'string';
-- param 'layer'; type 'number';
-- param 'value'; type 'string';
-- returns; type 'bool';
local function setMaterialProperty(material, property, layer, value)

  if type(material) == "string" then
    material = scenetree.findObject(material)
  end

  if material.___type == "class<Material>" then
    material:setField(property, layer, value)
    material:reload()
    return true
  else
    log('E', "", "Given object is not a material.")
    return false
  end
end

-- Removes a single material entry from a materials.json file using text manipulation.
-- This avoids re-serializing the whole file (jsonWriteFile sorts keys alphabetically),
-- which would otherwise reorder every entry and produce huge diffs in version control.
local function removeMaterialFromJson(materialName, materialFilename)
  local content = readFile(materialFilename)
  if not content then
    log('E', logTag, "Could not read material file: " .. tostring(materialFilename))
    return
  end

  local n = #content

  -- Locate the top-level key by tracking object/array depth and string state.
  -- A top-level key is a string at depth 1 (directly inside the root object)
  -- that is immediately followed by a ':'. This is independent of indentation
  -- and whitespace, so it still works on hand-edited / reformatted files.
  local depth = 0
  local inString = false
  local escaped = false
  local strStart
  local keyStart, keyEnd
  local i = 1
  while i <= n do
    local c = content:sub(i, i)
    if inString then
      if escaped then escaped = false
      elseif c == '\\' then escaped = true
      elseif c == '"' then
        inString = false
        if depth == 1 then
          -- Peek at the next non-whitespace char: ':' means this string is a key.
          local j = i + 1
          while j <= n and content:sub(j, j):match('%s') do j = j + 1 end
          if content:sub(j, j) == ':' and content:sub(strStart + 1, i - 1) == materialName then
            keyStart, keyEnd = strStart, i
            break
          end
        end
      end
    else
      if c == '"' then inString = true; strStart = i
      elseif c == '{' or c == '[' then depth = depth + 1
      elseif c == '}' or c == ']' then depth = depth - 1 end
    end
    i = i + 1
  end

  if not keyStart then
    log('W', logTag, "Material '" .. materialName .. "' not found in " .. materialFilename)
    return
  end

  -- Find the opening brace of the value object.
  local braceStart = content:find('{', keyEnd)
  if not braceStart then
    log('E', logTag, "Malformed material entry for '" .. materialName .. "' in " .. materialFilename)
    return
  end

  -- Scan to the matching closing brace, ignoring braces inside strings.
  depth = 0
  inString = false
  escaped = false
  local valueEnd
  for k = braceStart, n do
    local c = content:sub(k, k)
    if inString then
      if escaped then escaped = false
      elseif c == '\\' then escaped = true
      elseif c == '"' then inString = false end
    else
      if c == '"' then inString = true
      elseif c == '{' then depth = depth + 1
      elseif c == '}' then
        depth = depth - 1
        if depth == 0 then valueEnd = k break end
      end
    end
  end

  if not valueEnd then
    log('E', logTag, "Could not find end of material entry for '" .. materialName .. "' in " .. materialFilename)
    return
  end

  -- Find the previous non-whitespace char before the key to decide comma handling.
  local p = keyStart - 1
  while p >= 1 and content:sub(p, p):match('%s') do p = p - 1 end
  local prevChar = content:sub(p, p)

  local removeStart, removeEnd
  if prevChar == ',' then
    -- Not the first entry: drop the comma that joined the previous sibling to this
    -- one. Any trailing comma after the value stays and joins prev -> next.
    removeStart, removeEnd = p, valueEnd
  else
    -- First entry (prevChar is the root '{', or anything else): keep that char and
    -- remove from just after it, plus a trailing comma if another entry follows.
    removeStart, removeEnd = p + 1, valueEnd
    local q = valueEnd + 1
    while q <= n and content:sub(q, q):match('%s') do q = q + 1 end
    if content:sub(q, q) == ',' then removeEnd = q end
  end

  content = content:sub(1, removeStart - 1) .. content:sub(removeEnd + 1)
  writeFile(materialFilename, content)
end

-- Moves a material to another materials.json file (existing or new) and removes it from its source file.
-- param 'material'; type 'class<Material>' || 'string';
-- param 'newFilename'; type 'string';
-- returns; type 'bool';
local function moveMaterial(material, newFilename)
  if type(material) == "string" then
    material = scenetree.findObject(material)
  end

  if not material or material.___type ~= "class<Material>" then
    log('E', "", "Given object is not a material.")
    return false
  end

  local oldFilename = material:getFilename()
  if oldFilename == newFilename then
    log('W', "", "Material is already in the given file.")
    return false
  end

  local directory = path.split(newFilename)
  if FS:directoryExists(directory) == false then
    log('E', logTag, "Given directory '" .. directory .. "' does not exist!")
    editor.showNotification("Given directory '" .. directory .. "' does not exist!")
    return false
  end

  local materialName = material:getField("name", 0)

  material:setFilename(newFilename)
  material.canSave = true
  scenetree.matLuaEd_PersistMan:setDirty(material, '')
  scenetree.matLuaEd_PersistMan:saveDirty()

  local _, _, oldExt = path.split(oldFilename)
  if oldExt == "json" and FS:fileExists(oldFilename) then
    removeMaterialFromJson(materialName, oldFilename)
  end

  return true
end

-- Max number of layers for materials v1.5
local maxMaterialLayers = 4

-- Only material parameters are copied, the SimObject fields identify the object,
-- hold its namespaces or control its persistence.
local dontCopyFields = {
  name = true,
  mapTo = true,
  persistentId = true,
  parentGroup = true,
  internalName = true,
  class = true,
  className = true,
  superClass = true,
  hidden = true,
  locked = true,
  canSave = true,
  canSaveDynamicFields = true,
}

local function resolveMaterial(material)
  if type(material) == "string" then
    material = scenetree.findObject(material)
  end
  if not material or material.___type ~= "class<Material>" then
    log('E', "", "Given object is not a material.")
    return nil
  end
  return material
end

local function residesInJson(material)
  local filename = material:getFilename()
  if not filename or #filename == 0 then return false end
  local _, _, extension = path.split(filename)
  return extension == "json"
end

-- Copies all parameters of a material onto another one, for all layers.
local function copyMaterialFields(source, target)
  for fieldName, _ in pairs(source:getFields()) do
    if not dontCopyFields[fieldName] then
      for layer = 0, maxMaterialLayers - 1 do
        target:setField(fieldName, layer, source:getField(fieldName, layer))
      end
    end
  end

  for _, fieldName in ipairs(source:getDynamicFields() or {}) do
    if not dontCopyFields[fieldName] then
      target:setDynDataFieldbyName(fieldName, 0, source:getDynDataFieldbyName(fieldName, 0))
    end
  end
end

-- Copies all parameters of a material onto an existing material, keeping the target's name, mapTo and file.
-- param 'source'; type 'class<Material>' || 'string';
-- param 'target'; type 'class<Material>' || 'string';
-- returns; type 'bool';
local function copyMaterial(source, target)
  source = resolveMaterial(source)
  target = resolveMaterial(target)
  if not source or not target then return false end

  if source:getId() == target:getId() then
    log('E', logTag, "Cannot copy a material onto itself.")
    editor.showNotification("Cannot copy a material onto itself.")
    return false
  end

  if not residesInJson(target) then
    log('E', logTag, "Target material needs to reside in a json file.")
    editor.showNotification("Target material needs to reside in a json file.")
    return false
  end

  copyMaterialFields(source, target)
  target:reload()

  scenetree.matLuaEd_PersistMan:setDirty(target, '')
  scenetree.matLuaEd_PersistMan:saveDirty()
  return true
end

-- Copies a material into a new material with the given name, written to the given materials.json file.
-- param 'source'; type 'class<Material>' || 'string';
-- param 'newName'; type 'string';
-- param 'newFilename'; type 'string';
-- returns; type 'bool';
local function copyMaterialAsNew(source, newName, newFilename)
  source = resolveMaterial(source)
  if not source then return false end

  if #newName == 0 then
    log('E', logTag, 'Material name must not be empty!')
    editor.showNotification("Material name must not be empty!")
    return false
  end

  if scenetree.findObject(newName) then
    log('E', logTag, "A material with the given name '" .. newName .. "' already exists!")
    editor.showNotification("A material with the given name '" .. newName .. "' already exists!")
    return false
  end

  local directory = path.split(newFilename)
  if FS:directoryExists(directory) == false then
    log('E', logTag, "Given directory '" .. directory .. "' does not exist!")
    editor.showNotification("Given directory '" .. directory .. "' does not exist!")
    return false
  end

  local mat = createObject('Material')
  mat:setFilename(newFilename)
  copyMaterialFields(source, mat)
  mat:setField('name', 0, newName)
  mat:setField('mapTo', 0, newName)
  mat.canSave = true
  mat:registerObject(newName)

  scenetree.matLuaEd_PersistMan:setDirty(mat, '')
  scenetree.matLuaEd_PersistMan:saveDirty()
  return true
end

local function deleteMaterial(material)
  if type(material) == "string" then
    material = scenetree.findObject(material)
  end

  if material.___type == "class<Material>" then
    local materialName = material:getField("name", 0)
    local materialFilename = material:getFilename()
    material:delete()

    removeMaterialFromJson(materialName, materialFilename)
    return true
  else
    log('E', "", "Given object is not a material.")
    return false
  end
end

local function initialize(editorInstance)
  if not scenetree.materialPersistMan then
    local persistenceMgr = PersistenceManager()
    persistenceMgr:registerObject('materialPersistMan')
  end

  editor = editorInstance
  editor.createMaterial = createMaterial
  editor.setMaterialProperty = setMaterialProperty
  editor.removeMaterialFromJson = removeMaterialFromJson
  editor.moveMaterial = moveMaterial
  editor.copyMaterial = copyMaterial
  editor.copyMaterialAsNew = copyMaterialAsNew
  editor.deleteMaterial = deleteMaterial
end

local M = {}
M.initialize = initialize

return M