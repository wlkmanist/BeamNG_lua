-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local objects = nil
local luaType = type
local im = ui_imgui
local ffi = require("ffi")

local function abort(job)
  return job and job.stop == true
end

local function ensureValidPath(p)
  if not p then return false, 'There is no material path' end
  if not string.match(p, "/") then return false, 'Incorrect path' end
  return true
end

local function parseCSMaterialFile(fn)
  local t = {}
  local f = io.open(fn, "r")
  if not f then return t end
  local titleS
  for line in f:lines() do
    local title = line:match('%b()')
    local key = line:match("(.+)=(.+)")
    local value = line:match('%b""')
    if title then
      title = title:sub(2, -2)
      t[title] = t[title] or {}
      t[title].name = title
      titleS = title
    elseif key and value and titleS then
      key = key:gsub(' ', "")
      value = value:sub(2, -2)
      t[titleS][key] = value
    end
  end
  f:close()
  return t
end

local function parseMaterialFile(fn)
  if fn and string.endswith(fn, 'materials.cs') then
    return parseCSMaterialFile(fn)
  elseif fn and string.endswith(fn, 'materials.json') then
    return jsonReadFile(fn) or {}
  end
  return {}
end

local function parseMaterialFiles(files, job)
  local matTable = {}
  for _, fn in ipairs(files) do
    if abort(job) then return matTable end
    if FS:fileSize(fn) > 0 then
      matTable[fn] = parseMaterialFile(fn)
    end
    if job then job.yield() end
  end
  return matTable
end

local function foreachMaterial(matTable, cb)
  for file, mats in pairs(matTable) do
    for key, mat in pairs(mats) do
      cb(file, key, mat)
    end
  end
end

local function compactNested(map)
  local out, count = {}, 0
  for file, mats in pairs(map) do
    local hasAny = false
    for _, issues in pairs(mats) do
      if not tableIsEmpty(issues) then
        hasAny = true
        break
      end
    end
    if hasAny then
      out[file] = {}
      for matName, issues in pairs(mats) do
        if not tableIsEmpty(issues) then
          out[file][matName] = issues
        end
      end
      count = count + 1
    end
  end
  return out, count
end

local function collectFiles(root, pattern, skipCommon, vehAware)
  local files = FS:findFiles(root, pattern, -1, true, false)
  if skipCommon == false then
    if vehAware and string.match(root, "vehicles/") then
      arrayConcat(files, FS:findFiles("/vehicles/common", pattern, -1, true, false))
    end
    -- some callers also add art/core (keep compatibility)
    arrayConcat(files, FS:findFiles("/art", pattern, -1, true, false))
    arrayConcat(files, FS:findFiles("/core", pattern, -1, true, false))
  end
  return files
end

local function loadMaterialObjectsFromFile(fn)
  if fn and string.endswith(fn, 'materials.cs') then
    TorqueScript.exec(fn)
  elseif fn and string.endswith(fn, 'materials.json') then
    loadJsonMaterialsFile(fn)
  else
    return {}
  end
  return M.getSimObjects(fn)
end

local function safeFileSize(path)
  if not path or not FS:fileExists(path) or FS:isLinkFile(path) then return 0 end
  local s = FS:fileSize(path)
  return type(s) == 'number' and s or 0
end

-- helper to sum lists of filesizes
local function sumFilesize(list)
  local bytes = 0
  local count = 0
  if list then
    for _,p in ipairs(list) do
      count = count + 1
      bytes = bytes + safeFileSize(p)
    end
  end
  return count, bytes
end

local function onExtensionUnloaded()
  extensions.unload('extensions.editor_resourceChecker_resourceUtil')
end

--get scene tree all objects
local function getSimObjects(fileName)
  local ret = {}
  local objs = scenetree.getAllObjects()
  for _, objName in ipairs(objs) do
    local o = scenetree.findObject(objName)
    if o and o.getFileName and o:getFileName() == fileName then
      table.insert(ret, o)
    end
  end
  return ret
end

local function resaveMaterial(file)
  if file and FS:fileExists(file) then
    local persistenceMgr = PersistenceManager()
    persistenceMgr:registerObject('matFixOrder_PersistMan')
    loadJsonMaterialsFile(file)
    local objects = getSimObjects(file)
    if not tableIsEmpty(objects) then
      for _, obj in ipairs(objects) do
        if obj.___type == "class<Material>" then
          obj.persistentId = ""
          persistenceMgr:setDirty(obj, '')
        end
      end
      persistenceMgr:saveDirty()
    end
    persistenceMgr:delete()
  end
end

local hasBit = rawget(_G, 'bit') or rawget(_G, 'bit32')
local function powerOfTwo(x)
  if not x or x <= 0 then return false end
  if hasBit and hasBit.band then
    return hasBit.band(x, x - 1) == 0
  end
  local lg = math.log(x) / math.log(2)
  return lg == math.floor(lg)
end

local function removeFromForestJson(shape, foresData)
  local forestContent = jsonReadFile(foresData)
  if forestContent then
    local forestItem
    for k,v in pairs(forestContent) do
      if v.shapeFile == shape then
        forestItem = k
      end
    end
    if forestItem then
      log('I', '', 'Removing unused forestItem '..forestItem )
      forestContent[forestItem] = nil
      jsonWriteFile(foresData, forestContent, true)
    else
      log('W', '', 'Could not find '..shape )
    end
  end
end

--get material layers fields
local function getMaterialTexFields(mat)
  local fields = {}
  if mat and mat.___type == "class<Material>" then
    local layers = 1
    local version = mat:getField("version",0)
    if version == "0" or version == "1" then
      layers = 4
    elseif version == "1.5" then
      local al = tonumber(mat:getField("activeLayers",0)) or 1
      layers = math.max(1, al)
    end
    local meta = mat:getFields()
    for layer = 0, layers - 1 do
      for k,v in pairs(meta) do
        if v["type"] == "filename" then
          local filepth = mat:getField(k,layer)
          if filepth and filepth ~= "" then
            fields[k.."."..layer] = filepth
          end
        end
      end
    end
    return fields
  else
    log('E', '', 'Material not found' )
  end
end

local duplicatedM = {}
--look for duplicates
local function findDuplicates(duplicatelist)
  local seen1, seen2 = {}, {}
  duplicatedM = {}
  for _,v in pairs(duplicatelist) do
    local name, mapTo = v[1], v[2]
    if seen1[name] then
      duplicatedM[name] = true
    else
      seen1[name] = true
    end
    if mapTo and mapTo ~= "unmapped_mat" then
      if seen2[mapTo] then
        duplicatedM[name] = true
      else
        seen2[mapTo] = true
      end
    end
  end
end

--materials verifiers
local verifyVersionworkJob
local function verifyVersionwork(job, convertdata)
  local ok, err = ensureValidPath(convertdata)
  local isDone
  local count0 = 0
  local countPBR = 0
  local type = 2
  local isOld = {}
  local checkedMats = {}
  local output = {}
  job.progress = 0
  job.stop = nil
  if not ok then
    log('E', '', err )
    isDone = 2
  else
    log('I', '', 'Verifying materials version' )
    local materialFiles = FS:findFiles(convertdata, "*.cs\t*materials.json", -1, true, false)
    job.progress = 5
    job.sleep(0.001)
    for _, fn in ipairs(materialFiles) do
      if abort(job) then return end
      if string.endswith(fn, 'materials.cs') or string.endswith(fn, 'materials.json') then
        job.yield()
        objects = loadMaterialObjectsFromFile(fn)
      end
      if not tableIsEmpty(objects) then
        log('I', '', 'parsing all materials file: ' .. tostring(fn))
        for _, obj in ipairs(objects) do
          if abort(job) then return end
          if job.progress < 75 then
            job.progress = job.progress + 0.01
          end
          if obj.___type == "class<Material>" then
            job.yield()
            local name = obj:getName()
            local version = tonumber(obj:getField('version', 0))
            if version and version < 1.5 then
              if checkedMats[name] ~= true then
                checkedMats[name] = true
                count0 = count0 + 1
              end
              isOld[name] = obj:getFileName()
            elseif version == 1.5 then
              if checkedMats[name] ~= true then
                checkedMats[name] = true
                countPBR = countPBR + 1
              end
            end
          end
        end
      end
    end
    job.sleep(0.001)
    job.progress = 75
    for k,v in pairs(isOld) do
      job.yield()
      table.insert(output, k.."  in: "..v)
    end
    table.sort(output, function(a,b) return string.upper(a) < string.upper(b) end)
    job.sleep(0.001)
    log('I', '', 'Found ' ..tostring(count0).. ' old materials' )
    log('I', '', 'Found ' ..tostring(countPBR).. ' PBR materials' )
    isDone = 1
    job.progress = 100
  end
  local data = {type, count0, output, countPBR, isDone}
  extensions.editor_resourceChecker.jobData(2, data)
end
local function verifyVersion(convertdata)
  verifyVersionworkJob = extensions.core_jobsystem.create(verifyVersionwork, 1, convertdata)
end

local verifyDuplicateworkJob
local function verifyDuplicatework(job, convertdata, skipCommon)
  local ok, err = ensureValidPath(convertdata)
  local isDone
  local countduplicate = 0
  local duplicated = {}
  local type = 3
  local matTable = {}
  duplicatedM = {}
  job.progress = 0
  job.stop = nil
  if not ok then
    log('E', '', err )
    isDone = 2
  else
    log('I', '', 'Verifying materials duplicates' )
    local materialFiles = FS:findFiles(convertdata, "*.cs\t*materials.json", -1, true, false)
    if skipCommon == false then
      arrayConcat(materialFiles, FS:findFiles("/vehicles/common", "*.cs\t*materials.json", -1, true, false))
      arrayConcat(materialFiles, FS:findFiles("/art", "*.cs\t*materials.json", -1, true, false))
      arrayConcat(materialFiles, FS:findFiles("/core", "*.cs\t*materials.json", -1, true, false))
    end
    job.sleep(0.001)
    job.progress = 10
    matTable = parseMaterialFiles(materialFiles, job)
    if not tableIsEmpty(matTable) then
      log('I', '', 'parsing all materials')
      if abort(job) then return end
      local duplicatelist = {}
      for file, mats in pairs(matTable) do
        for k, mat in pairs(mats) do
          if mat and mat.name then
            log('I', '', ' * ' .. tostring(mat.name) .. ' - mapTo: ' .. tostring(mat.mapTo) )
            local matID = tostring(mat.name) .. '|' .. tostring(file) .. '|' .. tostring(k)
            duplicatelist[matID] = {mat.name, mat.mapTo, file}
            if job.progress < 50 then
              job.progress = job.progress + 0.01
            end
          else
            log('W', '', 'Corrupted or incompatible material found '..k)
          end
          job.yield()
        end
      end
      findDuplicates(duplicatelist)
    end
    job.progress = 50
    job.sleep(0.001)
    if abort(job) then return end
    job.progress = 90
    job.sleep(0.001)
    for k,_ in pairs(duplicatedM) do
      countduplicate = countduplicate + 1
      table.insert(duplicated, k)
    end
    table.sort(duplicated, function(a,b) return string.upper(a) < string.upper(b) end)
    log('I', '', 'Found ' ..tostring(countduplicate).. ' duplicates' )
    job.sleep(0.001)
    isDone = 1
    job.progress = 100
  end
  local data = {type, countduplicate, "dummy", duplicated, isDone}
  extensions.editor_resourceChecker.jobData(2, data)
end
local function verifyDuplicate(convertdata, skipCommon)
  verifyDuplicateworkJob = extensions.core_jobsystem.create(verifyDuplicatework, 1, convertdata, skipCommon)
end

local fixPIDworkJob
local function fixPIDwork(job, convertdata, skipCommon)
  local ok, err = ensureValidPath(convertdata)
  local isDone
  local type = 5
  local editedFiles = {}
  local outdatedFiles = {}
  local count = 0
  job.stop = nil
  job.progress = 0
  job.sleep(0.001)
  if not ok then
    log('E', '', err )
    isDone = 2
  else
    log('I', '', 'Removing PID' )
    local materialFiles = collectFiles(convertdata, "*materials.json", skipCommon, true)
    job.progress = 10
    job.sleep(0.001)
    if abort(job) then return end
    local matTable = parseMaterialFiles(materialFiles, job)
    job.sleep(0.001)
    job.progress = 20
    if not tableIsEmpty(matTable) then
      log('I', '', 'parsing all materials')
      foreachMaterial(matTable, function(path, _, mat)
        if abort(job) then return end
        if mat and mat.persistentId then
          job.yield()
          outdatedFiles[path] = true
          count = count + 1
        end
      end)
    end
    job.progress = 65
    job.sleep(0.001)
    for k,_ in pairs(outdatedFiles) do
      log('I', '', 'Saved materials to '..k )
      resaveMaterial(k)
      table.insert(editedFiles, k)
    end
    table.sort(editedFiles, function(a,b) return string.upper(a) < string.upper(b) end)
    log('I', '', 'Removed '..count..' persistendIds' )
    job.progress = 100
    job.sleep(0.001)
    isDone = 1
  end
  local data = {type, count, "", editedFiles, isDone}
  extensions.editor_resourceChecker.jobData(2, data)
end
local function fixPID(convertdata, skipCommon)
  fixPIDworkJob = extensions.core_jobsystem.create(fixPIDwork, 1, convertdata, skipCommon)
end

local checkMatTexworkJob
local function checkMatTexwork(job, convertdata)
  local ok, err = ensureValidPath(convertdata)
  local isDone
  local type = 6
  local fileIsMissing = {}
  local countmissing = 0
  local incorrectPath = {}
  local countpath = 0
  local incorrectPathCooker = {}
  local countcooker = 0
  local issuesTab = {}
  local matData = {}
  job.progress = 0
  job.sleep(0.001)
  job.stop = nil
  if not ok then
    log('E', '', err )
    isDone = 2
  else
    log('I', '', 'Checking texture maps' )
    local materialFiles = FS:findFiles(convertdata, "*.cs\t*materials.json", -1, true, false)
    job.progress = 10
    job.sleep(0.001)
    if abort(job) then return end
    for _, fn in ipairs(materialFiles) do
      if abort(job) then return end
      job.yield()
      matData[fn] = {}
      objects = loadMaterialObjectsFromFile(fn)
      if not tableIsEmpty(objects) then
        log('I', '', 'parsing all materials file: ' .. tostring(fn))
        job.yield()
        for _, obj in ipairs(objects) do
          if abort(job) then return end
          job.yield()
          if obj.___type == "class<Material>" then
            local texfields = getMaterialTexFields(obj)
            if texfields then
              matData[fn][obj:getName()] = {}
              for k,v in pairs(texfields) do
                matData[fn][obj:getName()][k] = v
              end
            end
          elseif obj.___type == "class<TerrainMaterial>" then
            local texfields = {}
            for k,v in pairs(obj:getFields()) do
              if v["type"] == "filename" then
                texfields[k] = obj:getField(k,0)
              end
            end
            matData[fn][obj:getName()] = {}
            for k,v in pairs(texfields) do
              matData[fn][obj:getName()][k] = v
            end
          end
        end
      end
      local cases = {".color.png", ".normal.png", ".data.png", ".color.dds", ".normal.dds", ".data.dds", ".dds", ".png", ".bmp", ".jpg", ".jpeg", ".tga"}
      for e,t in pairs(matData) do
        fileIsMissing[e] = {}
        incorrectPath[e] = {}
        incorrectPathCooker[e] = {}
        for k,v in pairs(t) do
          if job.progress < 75 then job.progress = job.progress + 0.001 end
          fileIsMissing[e][k] = {}
          incorrectPath[e][k] = {}
          incorrectPathCooker[e][k] = {}
          for m,d in pairs(v) do
            job.yield()
            local dir, basefilename, ext = path.splitWithoutExt(d)
            if d and d ~= "" then
              for _,b in pairs(cases) do
                if d:find(b) then
                  if d:find(".color.png") or d:find(".data.png") or d:find(".normal.png") then
                    if not (FS:fileExists(dir..basefilename..".png") or FS:fileExists(dir..basefilename..".dds")) then
                      fileIsMissing[e][k][m] = d.."   Reason: File not found"
                    end
                  elseif dir then
                    if not FS:fileExists(dir..basefilename..b) then fileIsMissing[e][k][m] = d.."   Reason: File not found" end
                  end
                  if d:find(".color.dds") or d:find(".data.dds") or d:find(".normal.dds") then
                    if FS:fileExists(dir..basefilename..".png") or FS:fileExists(dir..basefilename..".dds") then
                      incorrectPathCooker[e][k][m] = d.."   Reason: cannot be cooked, wrong postfix, use png in texture cooker files"
                    else fileIsMissing[e][k][m] = d.."   Reason: File not found" end
                  end
                  if d:find(".color") or d:find(".data") or d:find(".normal") then
                    if not dir then incorrectPath[e][k][m] = d.."   Reason: Path does not contain directory" end
                    if not ext then incorrectPath[e][k][m] = d.."   Reason: Path does not contain extension" end
                  end
                  if dir then
                    local root = string.lower(convertdata):gsub('/levels/','levels/'):gsub('/vehicles/','vehicles/')
                    if not string.lower(dir):find(root) then
                      if dir:find("levels/") then
                        incorrectPath[e][k][m] = d.."   Reason: Path leads to a different level, might cause issues"
                      elseif dir:find("vehicles/") and not dir:find("vehicles/common/") then
                        incorrectPath[e][k][m] = d.."   Reason: Path leads to a different vehicle, might cause issues"
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
    if abort(job) then return end
    local tempTable
    job.progress = 75
    job.sleep(0.001)
    tempTable = select(1, compactNested(incorrectPathCooker))
    incorrectPathCooker = tempTable
    _, countcooker = compactNested(incorrectPathCooker)

    tempTable = select(1, compactNested(incorrectPath))
    incorrectPath = tempTable
    _, countpath = compactNested(incorrectPath)

    tempTable = select(1, compactNested(fileIsMissing))
    fileIsMissing = tempTable
    _, countmissing = compactNested(fileIsMissing)

    job.progress = 90
    job.sleep(0.001)
    issuesTab["Incorrect Path for Texture Cooker"] = incorrectPathCooker
    issuesTab["Incorrect Path"] = incorrectPath
    issuesTab["Missing File"] = fileIsMissing
    job.progress = 100
    job.sleep(0.001)
    log('I', '', 'Checked all materials textures mapping' )
    isDone = 1
  end
  local data = {type, countpath, countmissing, issuesTab, isDone, countcooker}
  extensions.editor_resourceChecker.jobData(2, data)
end
local function checkMatTex(convertdata)
  checkMatTexworkJob = extensions.core_jobsystem.create(checkMatTexwork, 1, convertdata)
end

local checkTexworkJob
local function checkTexwork(job, convertdata)
  local ok, err = ensureValidPath(convertdata)
  local isDone
  local type = 7
  local countp2 = 0
  local pow2 = {}
  local countcooker = 0
  local cooker = {}
  local issuesTab = {}
  local countext = 0
  local fileext = {}
  local matData = {}
  job.progress = 0
  job.sleep(0.001)
  job.stop = nil
  if not ok then
    log('E', '', err )
    isDone = 2
  else
    log('I', '', 'Checking texture maps' )
    local materialFiles = FS:findFiles(convertdata, "*.cs\t*materials.json", -1, true, false)
    local sorted = {}
    for k,v in pairs(materialFiles) do
      if string.find(v, '/terrains/') and string.find(v, '/terrain/') then
      else
        sorted[k] = v
      end
    end
    materialFiles = sorted
    job.progress = 10
    job.sleep(0.001)
    for _, fn in ipairs(materialFiles) do
      if abort(job) then return end
      job.yield()
      matData[fn] = {}
      objects = loadMaterialObjectsFromFile(fn)
      if not tableIsEmpty(objects) then
        log('I', '', 'parsing all materials file: ' .. tostring(fn))
        for _, obj in ipairs(objects) do
          job.yield()
          if obj.___type == "class<Material>" then
            local texfields = getMaterialTexFields(obj)
            if texfields then
              matData[fn][obj:getName()] = {}
              for k,v in pairs(texfields) do
                matData[fn][obj:getName()][k] = v
              end
            end
          end
        end
      end
      for e,t in pairs(matData) do
        pow2[e] = {}
        fileext[e] = {}
        cooker[e] = {}
        for k,v in pairs(t) do
          if job.progress < 75 then
            job.progress = job.progress + 0.001
          end
          pow2[e][k] = {}
          fileext[e][k] = {}
          cooker[e][k] = {}
          for m,d in pairs(v) do
            if abort(job) then return end
            job.yield()
            if d and d ~= "" and FS:fileExists(d) then
              local tex = im.ImTextureHandler(d)
              local size = tex:getSize()
              local format = ffi.string(tex:getFormat())
              if not powerOfTwo(size.x) or not powerOfTwo(size.y) then
                pow2[e][k][m] = d.." Format: "..format.."   Reason: is not a power of 2"
              end
              if d:find("bmp") or d:find("jpg") or d:find("jpeg") or d:find("tga") then
                fileext[e][k][m] = d.." Format: "..format.."   Reason: not optimal format for textures"
              end
              if not d:find("color.png") and not d:find("normal.png") and not d:find("data.png") then
                if d:find("png") then
                  cooker[e][k][m] = d.." Format: "..format.."   Reason: cannot be cooked, missing postfix"
                end
              end
              if d:find("color.png") or d:find("normal.png") or d:find("data.png") then
                if not powerOfTwo(size.x) or not powerOfTwo(size.y) then
                  cooker[e][k][m] = d.." Format: "..format.."   Reason: cannot be cooked, is not a power of 2"
                end
                if format:find("R16G16B16") then
                  cooker[e][k][m] = d.." Format: "..format.."   Reason: cannot be cooked, is a 16 bit PNG"
                end
              end
            end
          end
        end
      end
    end
    job.progress = 75
    job.sleep(0.001)
    local tempTable
    tempTable = select(1, compactNested(cooker))
    cooker = tempTable
    _, countcooker = compactNested(cooker)

    tempTable = select(1, compactNested(fileext))
    fileext = tempTable
    _, countext = compactNested(fileext)

    tempTable = select(1, compactNested(pow2))
    pow2 = tempTable
    _, countp2 = compactNested(pow2)

    if abort(job) then return end
    job.progress = 90
    job.sleep(0.001)
    issuesTab["Incorrect File for Texture Cooker"] = cooker
    issuesTab["Incorrect File Format"] = fileext
    issuesTab["Incorrect Resolution"] = pow2
    job.progress = 100
    job.sleep(0.001)
    log('I', '', 'Checked all texture files' )
    isDone = 1
  end
  local data = {type, countext, countp2, issuesTab, isDone, countcooker}
  extensions.editor_resourceChecker.jobData(2, data)
end
local function checkTex(convertdata)
  checkTexworkJob = extensions.core_jobsystem.create(checkTexwork, 1, convertdata)
end

local checkmissingMatsworkJob
local function checkmissingMatswork(job, convertdata)
  local ok, err = ensureValidPath(convertdata)
  local isDone
  local type = 8
  local objmatTable = {}
  local mapping = {}
  local missingMat = {}
  local count = 0
  job.progress = 0
  job.sleep(0.001)
  job.stop = nil
  if not ok then
    log('E', '', err )
    isDone = 2
  else
    log('I', '', 'Checking missing materials mapping' )
    log('I', '', 'Checking material files' )
    local commonVeh = FS:findFiles("/vehicles/common", "*.cs\t*materials.json", -1, true, false)
    local commonArt = FS:findFiles("/art", "*.cs\t*materials.json", -1, true, false)
    local commonCore = FS:findFiles("/core", "*.cs\t*materials.json", -1, true, false)
    local materialFiles = FS:findFiles(convertdata, "*.cs\t*materials.json", -1, true, false)
    arrayConcat(materialFiles, commonVeh)
    arrayConcat(materialFiles, commonArt)
    arrayConcat(materialFiles, commonCore)
    job.progress = 20
    job.sleep(0.001)
    for _, fn in ipairs(materialFiles) do
      if abort(job) then return end
      job.yield()
      objects = loadMaterialObjectsFromFile(fn)
      if not tableIsEmpty(objects) then
        job.yield()
        log('I', '', 'parsing all materials file: ' .. tostring(fn))
        for _, obj in ipairs(objects) do
          if job.progress < 50 then job.progress = job.progress + 0.001 end
          job.yield()
          if obj.___type == "class<Material>" then
            mapping[obj:getField("mapTo",0)] = true
          end
        end
      end
    end
    job.progress = 50
    job.sleep(0.001)
    if abort(job) then return end
    log('I', '', 'Checking meshes for materials' )
    local meshFiles = FS:findFiles(convertdata, "*.dae\t*.dts\t*.cdae\t*.cached.dts", -1, true, false)
    for k,v in ipairs(meshFiles) do
      local dir, basefilename, ext = path.splitWithoutExt(v)
      if job.progress < 75 then job.progress = job.progress + 0.01 end
      job.yield()
      local shapeLoader = ShapePreview()
      shapeLoader:setObjectModel(v)
      log('I', '', 'Checking mesh '.. v)
      table.insert(objmatTable, {shapeLoader:getMaterialNames(), v})
      shapeLoader:clearShape()
    end
    job.progress = 75
    job.sleep(0.001)
    for _,v in pairs(objmatTable) do
      if job.progress < 90 then job.progress = job.progress + 0.01 end
      job.yield()
      if (luaType(v[1]) == "table") then
        for _,j in pairs(v[1]) do
          if not mapping[j] then
            log('I', '', 'Found missing mat '..j.. ' in: '..v[2] )
            table.insert(missingMat, j.."   Mesh: "..v[2])
            count = count + 1
          end
        end
      else
        log("E","", "Is not a table???")
      end
    end
    if abort(job) then return end
    table.sort(missingMat, function(a,b) return string.upper(a) < string.upper(b) end)
    job.progress = 100
    job.sleep(0.001)
    isDone = 1
  end
  local data = {type, count, "dummy", missingMat, isDone}
  extensions.editor_resourceChecker.jobData(2, data)
end
local function checkmissingMats(convertdata)
  checkmissingMatsworkJob = extensions.core_jobsystem.create(checkmissingMatswork, 1, convertdata)
end

--resource explorer (unchanged logic, minor refactors for safety/speed)
local checkStaticworkJob
local function checkStaticwork(job)
  log('I', '', 'Checking TSStatics' )
  local type = 1
  local isDone
  local countduplicate = 0
  local countScene = 0
  local size = 0
  local sizecache = 0
  job.progress = 0
  job.stop = nil
  job.sleep(0.001)
  local meshNames = scenetree.findClassObjects('TSStatic')
  local shapeList = {}
  job.progress = 20
  job.sleep(0.001)
  for i,v in ipairs(meshNames) do
    if abort(job) then return end
    if job.progress < 50 then job.progress = job.progress + 0.01 end
    job.yield()
    local m = scenetree.findObject(v)
    if not m then log("E", "", "TSStatic object broken "..dumps(v))
    else
      shapeList[m.shapeName] = true
      countScene = countScene + 1
    end
  end
  job.progress = 50
  job.sleep(0.001)
  local shapes = {}
  local shapesprepare = {}
  for k,_ in pairs(shapeList) do
    if abort(job) then return end
    if job.progress < 90 then job.progress = job.progress + 0.01 end
    job.yield()
    log('I', '', 'Found shape '..k )
    local fsize = safeFileSize(k)
    size = size + fsize
    local cacheSize = 0
    if FS:fileExists(k:gsub('.dae','.cdae')) then
      local fsize2 = safeFileSize(k:gsub('.dae','.cdae'))
      cacheSize = fsize2
      sizecache = sizecache + fsize2
    elseif FS:fileExists('/temp/'..k:gsub('.dae','.cdae')) then
      local fsize2 = safeFileSize('/temp/'..k:gsub('.dae','.cdae'))
      cacheSize = fsize2
      sizecache = sizecache + fsize2
    end
    table.insert(shapesprepare, {k,fsize,cacheSize})
    countduplicate = countduplicate + 1
  end
  table.sort(shapesprepare, function(a,b) return tonumber(a[3]) > tonumber(b[3]) end)
  for _,v in pairs(shapesprepare) do
    local sizeS = string.format("%.2f", v[2] / 1048576)
    local cachesize = string.format("%.2f", v[3] / 1048576)
    table.insert(shapes, v[1].." Collada size: "..sizeS.." MB. Cache size: "..cachesize.." MB")
  end
  job.progress = 90
  job.sleep(0.001)
  job.progress = 100
  job.sleep(0.001)
  isDone = 1
  size = string.format("%.2f", size/1048576)
  sizecache = string.format("%.2f", sizecache/1048576)
  local data = {type, countduplicate, countScene, shapes, isDone, size, sizecache}
  extensions.editor_resourceChecker.jobData(3, data)
end
local function checkStatic()
  checkStaticworkJob = extensions.core_jobsystem.create(checkStaticwork, 1)
end

local checkForestworkJob
local function checkForestwork(job)
  log('I', '', 'Checking ForestItemData' )
  local type = 2
  local isDone
  local countduplicate = 0
  job.progress = 0
  job.stop = nil
  job.sleep(0.001)
  local meshNames = scenetree.findClassObjects('ForestItemData')
  local shapeList = {}
  local size = 0
  local sizecache = 0
  job.progress = 20
  job.sleep(0.001)
  for _,v in ipairs(meshNames) do
    if abort(job) then return end
    if job.progress < 50 then job.progress = job.progress + 0.01 end
    job.yield()
    local m = scenetree.findObject(v)
    if not m then log("E", "", "ForestItem object broken "..dumps(v))
    else
      shapeList[m:getField("shapeFile",0)] = true
    end
  end
  job.progress = 50
  job.sleep(0.001)
  local shapes = {}
  local shapesprepare = {}
  for k,_ in pairs(shapeList) do
    if abort(job) then return end
    if job.progress < 90 then job.progress = job.progress + 0.01 end
    job.yield()
    log('I', '', 'Found ForestItem '..k )
    local fsize = safeFileSize(k)
    size = size + fsize
    local cacheSize = 0
    if FS:fileExists(k:gsub('.dae','.cdae')) then
      local fsize2 = safeFileSize(k:gsub('.dae','.cdae'))
      cacheSize = fsize2
      sizecache = sizecache + fsize2
    elseif FS:fileExists('/temp/'..k:gsub('.dae','.cdae')) then
      local fsize2 = safeFileSize('/temp/'..k:gsub('.dae','.cdae'))
      cacheSize = fsize2
      sizecache = sizecache + fsize2
    end
    table.insert(shapesprepare, {k,fsize,cacheSize})
    countduplicate = countduplicate + 1
  end
  table.sort(shapesprepare, function(a,b) return tonumber(a[3]) > tonumber(b[3]) end)
  for _,v in pairs(shapesprepare) do
    local sizeS = string.format("%.2f", v[2] / 1048576)
    local cachesize = string.format("%.2f", v[3] / 1048576)
    table.insert(shapes, v[1].." Collada size: "..sizeS.." MB. Cache size: "..cachesize.." MB")
  end
  job.progress = 90
  job.sleep(0.001)
  job.progress = 100
  job.sleep(0.001)
  isDone = 1
  size = string.format("%.2f", size/1048576)
  sizecache = string.format("%.2f", sizecache/1048576)
  local data = {type, countduplicate, "dummy", shapes, isDone, size, sizecache}
  extensions.editor_resourceChecker.jobData(3, data)
end
local function checkForest()
  checkForestworkJob = extensions.core_jobsystem.create(checkForestwork, 1)
end

local checkTerrainsworkJob
local function checkTerrainswork(job)
  log('I', '', 'Checking TerrainBlocks' )
  local type = 3
  local isDone
  local countduplicate = 0
  job.progress = 0
  job.stop = nil
  job.sleep(0.001)
  local meshNames = scenetree.findClassObjects('TerrainBlock')
  local shapeList = {}
  local size = 0
  job.progress = 20
  job.sleep(0.001)
  for _,v in ipairs(meshNames) do
    if abort(job) then return end
    job.yield()
    local m = scenetree.findObject(v)
    if not m then log("E", "", "TerrainBlock object broken "..dumps(v))
    else
      shapeList[m:getField("terrainFile",0)] = true
    end
  end
  job.progress = 50
  job.sleep(0.001)
  local shapes = {}
  for k,_ in pairs(shapeList) do
    if abort(job) then return end
    job.yield()
    table.insert(shapes, k)
    log('I', '', 'Found terrain '..k )
    local fsize = safeFileSize(k)
    size = size + fsize
    countduplicate = countduplicate + 1
  end
  table.sort(shapes, function(a,b) return string.upper(a) < string.upper(b) end)
  job.progress = 90
  job.sleep(0.001)
  job.progress = 100
  job.sleep(0.001)
  isDone = 1
  size = string.format("%.2f", size/1048576)
  local data = {type, countduplicate, size, shapes, isDone}
  extensions.editor_resourceChecker.jobData(3, data)
end
local function checkTerrains()
  checkTerrainsworkJob = extensions.core_jobsystem.create(checkTerrainswork, 1)
end

local matstoRemove = {}
local checkUnusedMatsworkJob
local function checkUnusedMatswork(job, levelname, removal)
  local type = 4
  local isDone
  local countduplicate = 0
  local unused = {}
  local shapes = {}
  job.progress = 0
  job.sleep(0.001)
  job.stop = nil
  if not levelname then
    log('E', '', 'There is no level name' )
    isDone = 2
  else
    log('I', '', 'Checking for unused materials' )
    log('I', '', 'Checking Prefabs' )
    local shapeList = {}
    job.progress = 5
    local prefabs = FS:findFiles("/levels/"..levelname.."/", "*.prefab\t*.prefab.json", -1, true, false)
    local missionPrefabs = FS:findFiles("/gameplay/missions/"..levelname.."/", "*.prefab\t*.prefab.json", -1, true, false)
    arrayConcat(prefabs, missionPrefabs)
    for _, fn in ipairs(prefabs) do
      if abort(job) then return end
      job.yield()
      if FS:fileSize(fn) > 0 then
        if string.endswith(fn, 'prefab') then
          log('I', '', 'Loading ts prefab file '..fn )
          local f = io.open(fn, "r")
          if f then
            for line in f:lines() do
              job.yield()
              if line:match('shapeName') then
                line = line:gsub('shapeName', ''):gsub('"', ""):gsub(' ', ""):gsub(';', ""):gsub('=', "")
                shapeList[line] = true
              end
            end
            f:close()
          end
        elseif string.endswith(fn, 'prefab.json') then
          log('I', '', 'Loading json prefab file '..fn )
          local f = io.open(fn, "r")
          for line in f:lines() do
            job.yield()
            local data = json.decode(line)
            if data.shapeName then
              shapeList[data.shapeName] = true
            end
          end
          f:close()
        end
      end
    end
    log('I', '', 'Checking ForestItemData' )
    local meshNames = scenetree.findClassObjects('ForestItemData')
    local objmatTable = {}
    local mats = {}
    job.progress = 10
    job.sleep(0.001)
    for _,v in pairs(meshNames) do
      if abort(job) then return end
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "ForestItem object broken "..dumps(v))
      else
        shapeList[m:getField("shapeFile",0)] = true
      end
    end
    job.progress = 15
    job.sleep(0.001)
    for k,_ in pairs(shapeList) do
      if abort(job) then return end
      job.yield()
      if FS:fileExists(k) then
        local shapeLoader = ShapePreview()
        shapeLoader:setObjectModel(k)
        table.insert(objmatTable, shapeLoader:getMaterialNames())
        shapeLoader:clearShape()
      end
    end
    job.progress = 20
    job.sleep(0.001)
    log('I', '', 'Checking TSStatics' )
    local meshNames2 = scenetree.findClassObjects('TSStatic')
    for _,v in pairs(meshNames2) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "TSStatic object broken "..dumps(v))
      else
        table.insert(objmatTable, m:getMaterialNames())
      end
    end
    job.progress = 25
    job.sleep(0.001)
    for _,v in pairs(objmatTable) do
      job.yield()
      if (luaType(v) == "table") then
        for _,vv in pairs(v) do
          mats[vv] = true
        end
      else
        log("E","", "Is not a table???")
      end
    end
    job.progress = 30
    job.sleep(0.001)
    local terrainMats = {}
    log('I', '', 'Checking TerrainBlocks' )
    local meshNames3 = scenetree.findClassObjects('TerrainBlock')
    for _,v in pairs(meshNames3) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "TerrainBlock object broken "..dumps(v))
      else
        table.insert(terrainMats, m:getMaterials())
      end
    end
    job.progress = 35
    job.sleep(0.001)
    for _,v in pairs(terrainMats) do
      job.yield()
      for _,vv in pairs(v) do
        mats[vv:getInternalName()] = true
      end
    end
    job.progress = 40
    job.sleep(0.001)
    log('I', '', 'Checking GroundPlanes' )
    local meshNames4 = scenetree.findClassObjects('GroundPlane')
    for _,v in pairs(meshNames4) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "GroundPlane object broken "..dumps(v))
      else
        mats[m:getField("Material",0)] = true
      end
    end
    job.progress = 45
    job.sleep(0.001)
    log('I', '', 'Checking GroundCovers' )
    local meshNames5 = scenetree.findClassObjects('GroundCover')
    for _,v in pairs(meshNames5) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "GroundCover object broken "..dumps(v))
      else
        mats[m:getField("Material",0)] = true
      end
    end
    job.progress = 50
    job.sleep(0.001)
    log('I', '', 'Checking DecalRoads' )
    local meshNames6 = scenetree.findClassObjects('DecalRoad')
    for _,v in pairs(meshNames6) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "DecalRoad object broken "..dumps(v))
      else
        mats[m:getField("Material",0)] = true
      end
    end
    job.progress = 55
    job.sleep(0.001)
    log('I', '', 'Checking MeshRoads' )
    local meshNames7 = scenetree.findClassObjects('MeshRoad')
    for _,v in pairs(meshNames7) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "MeshRoad object broken "..dumps(v))
      else
        mats[m:getField("topMaterial",0)] = true
        mats[m:getField("sideMaterial",0)] = true
        mats[m:getField("bottomMaterial",0)] = true
      end
    end
    job.progress = 60
    job.sleep(0.001)
    log('I', '', 'Checking DecalData' )
    local meshNames8 = scenetree.findClassObjects('DecalData')
    for _,v in pairs(meshNames8) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "DecalData object broken "..dumps(v))
      else
        mats[m:getField("Material",0)] = true
      end
    end
    job.progress = 65
    job.sleep(0.001)
    if abort(job) then return end
    local materialFiles
    if removal == 1 then
      materialFiles = FS:findFiles("/levels/"..levelname.."/", "*materials.json", -1, true, false)
    else
      materialFiles = FS:findFiles("/levels/"..levelname.."/", "*.cs\t*materials.json", -1, true, false)
    end
    local blacklist = {"cubemaps"}
    local matTable = {}
    for _, fn in ipairs(materialFiles) do
      job.yield()
      for _,b in ipairs(blacklist) do
        if fn:find(b) then
          goto skipFile
        end
      end
      if abort(job) then return end
      if FS:fileSize(fn) > 0 then
        if string.endswith(fn, 'materials.json') then
          log('I', '', 'Loading json material file '..fn )
          matTable[fn] = jsonReadFile(fn) or {}
        end
      end
      ::skipFile::
    end
    job.progress = 70
    job.sleep(0.001)
    local materialFilesdata = {}
    if abort(job) then return end
    if not tableIsEmpty(matTable) then
      log('I', '', 'parsing all materials')
      for path, mats in pairs(matTable) do
        job.yield()
        for k,v in pairs(mats) do
          local mat = v
          if mat and mat.name and mat.mapTo and not mat.internalName then
            materialFilesdata[mat.name] = mat.mapTo
          elseif mat and mat.name and mat.internalName then
            materialFilesdata[mat.internalName] = mat.internalName
          elseif mat and (not mat.name or not mat.internalName) then
            log('W', '', 'Corrupted or incompatible material found '..k)
          end
        end
      end
    end
    job.progress = 75
    job.sleep(0.001)
    local tmpMats = {}
    for k,_ in pairs(mats) do
      job.yield()
      k = string.lower(k)
      tmpMats[k] = true
    end
    mats = tmpMats
    for k,v in pairs(materialFilesdata) do
      job.yield()
      if not (mats[string.lower(k)] or mats[string.lower(v)]) then
        log('I', '', 'Found unused material '..v )
        unused[k] = v
      end
    end
    job.progress = 85
    job.sleep(0.001)
    for k,_ in pairs(unused) do
      job.yield()
      local m = scenetree.findObject(k)
      if m and m:getFileName() then
        table.insert(shapes, k.."  in: "..m:getFileName())
        countduplicate = countduplicate + 1
      end
    end
    table.sort(shapes, function(a,b) return string.upper(a) < string.upper(b) end)
    job.progress = 100
    job.sleep(0.001)
    isDone = 1
  end
  local data = {type, countduplicate, "dummy", shapes, isDone}
  if removal == 1 then
    local toRemove = {}
    for k,_ in pairs(unused) do
      job.yield()
      local m = scenetree.findObject(k)
      if m and m:getFileName() then
        toRemove[k] = m:getFileName()
      end
    end
    M.matstoRemove = toRemove
  else
    extensions.editor_resourceChecker.jobData(3, data)
  end
end
local function checkUnusedMats(levelname, removal)
  checkUnusedMatsworkJob = extensions.core_jobsystem.create(checkUnusedMatswork, 1, levelname, removal)
end

local checkUsedMatsworkJob
local function checkUsedMatswork(job, levelname)
  local type = 8
  local isDone
  local countduplicate = 0
  local sizeTotal = 0
  local shapes = {}
  local usages = {}
  job.progress = 0
  job.sleep(0.001)
  job.stop = nil
  if not levelname then
    log('E', '', 'There is no level name' )
    isDone = 2
  else
    log('I', '', 'Checking for used materials' )
    log('I', '', 'Checking Prefabs' )
    local shapeList = {}
    local matsInObjects = {}
    job.progress = 5
    local prefabs = {}
    local prefabInstances = scenetree.findClassObjects('Prefab')
    for _,v in pairs(prefabInstances) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "Prefab object broken "..dumps(v))
      else
        if m:getField('filename',0) then
          table.insert(prefabs, m:getField('filename',0))
        end
      end
    end
    for _, fn in ipairs(prefabs) do
      if abort(job) then return end
      job.yield()
      if FS:fileSize(fn) > 0 then
        if string.endswith(fn, 'prefab') then
          log('I', '', 'Loading ts prefab file '..fn )
          local f = io.open(fn, "r")
          if f then
            for line in f:lines() do
              job.yield()
              if line:match('shapeName') then
                line = line:gsub('shapeName', ''):gsub('"', ""):gsub(' ', ""):gsub(';', ""):gsub('=', "")
                shapeList[line] = true
              end
            end
            f:close()
          end
        elseif string.endswith(fn, 'prefab.json') then
          log('I', '', 'Loading json prefab file '..fn )
          local f = io.open(fn, "r")
          for line in f:lines() do
            job.yield()
            local data = json.decode(line)
            if data.shapeName then
              shapeList[data.shapeName] = true
            end
          end
          f:close()
        end
      end
    end
    log('I', '', 'Checking ForestItemData' )
    local meshNames = scenetree.findClassObjects('ForestItemData')
    local objmatTable = {}
    local mats = {}
    local allMatsUsages = {}
    job.progress = 10
    job.sleep(0.001)
    for _,v in pairs(meshNames) do
      if abort(job) then return end
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "ForestItem object broken "..dumps(v))
      else
        shapeList[m:getField("shapeFile",0)] = true
      end
    end
    job.progress = 15
    job.sleep(0.001)
    for k,_ in pairs(shapeList) do
      if abort(job) then return end
      job.yield()
      if FS:fileExists(k) then
        local shapeLoader = ShapePreview()
        shapeLoader:setObjectModel(k)
        table.insert(objmatTable, shapeLoader:getMaterialNames())
        matsInObjects[k] = shapeLoader:getMaterialNames()
        shapeLoader:clearShape()
      end
    end
    job.progress = 20
    job.sleep(0.001)
    log('I', '', 'Checking TSStatics' )
    local meshNames2 = scenetree.findClassObjects('TSStatic')
    for _,v in pairs(meshNames2) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "TSStatic object broken "..dumps(v))
      else
        table.insert(objmatTable, m:getMaterialNames())
        matsInObjects[m:getModelFile()] = m:getMaterialNames()
      end
    end
    job.progress = 25
    job.sleep(0.001)
    for _,v in pairs(objmatTable) do
      job.yield()
      if (luaType(v) == "table") then
        for _,vv in pairs(v) do
          mats[vv] = true
          table.insert(allMatsUsages, vv)
        end
      else
        log("E","", "Is not a table???")
      end
    end
    job.progress = 30
    job.sleep(0.001)
    local terrainMats = {}
    log('I', '', 'Checking TerrainBlocks' )
    local meshNames3 = scenetree.findClassObjects('TerrainBlock')
    for _,v in pairs(meshNames3) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "TerrainBlock object broken "..dumps(v))
      else
        table.insert(terrainMats, m:getMaterials())
      end
    end
    job.progress = 35
    job.sleep(0.001)
    for _,v in pairs(terrainMats) do
      job.yield()
      for _,vv in pairs(v) do
        mats[vv:getInternalName()] = true
        table.insert(allMatsUsages, vv:getInternalName())
      end
    end
    job.progress = 40
    job.sleep(0.001)
    log('I', '', 'Checking GroundPlanes' )
    local meshNames4 = scenetree.findClassObjects('GroundPlane')
    for _,v in pairs(meshNames4) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "GroundPlane object broken "..dumps(v))
      else
        mats[m:getField("Material",0)] = true
        table.insert(allMatsUsages, m:getField("Material",0))
        if not matsInObjects['GroundPlanes'] then matsInObjects['GroundPlanes'] = {} end
        table.insert(matsInObjects['GroundPlanes'], m:getField("Material",0))
      end
    end
    job.progress = 45
    job.sleep(0.001)
    log('I', '', 'Checking GroundCovers' )
    local meshNames5 = scenetree.findClassObjects('GroundCover')
    for _,v in pairs(meshNames5) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "GroundCover object broken "..dumps(v))
      else
        mats[m:getField("Material",0)] = true
        table.insert(allMatsUsages, m:getField("Material",0))
        if not matsInObjects['GroundCovers'] then matsInObjects['GroundCovers'] = {} end
        table.insert(matsInObjects['GroundCovers'], m:getField("Material",0))
      end
    end
    job.progress = 50
    job.sleep(0.001)
    log('I', '', 'Checking DecalRoads' )
    local meshNames6 = scenetree.findClassObjects('DecalRoad')
    for _,v in pairs(meshNames6) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "DecalRoad object broken "..dumps(v))
      else
        mats[m:getField("Material",0)] = true
        table.insert(allMatsUsages, m:getField("Material",0))
        if not matsInObjects['DecalRoads'] then matsInObjects['DecalRoads'] = {} end
        table.insert(matsInObjects['DecalRoads'], m:getField("Material",0))
      end
    end
    job.progress = 55
    job.sleep(0.001)
    log('I', '', 'Checking MeshRoads' )
    local meshNames7 = scenetree.findClassObjects('MeshRoad')
    for _,v in pairs(meshNames7) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "MeshRoad object broken "..dumps(v))
      else
        mats[m:getField("topMaterial",0)] = true
        mats[m:getField("sideMaterial",0)] = true
        mats[m:getField("bottomMaterial",0)] = true
        table.insert(allMatsUsages, m:getField("topMaterial",0))
        table.insert(allMatsUsages, m:getField("sideMaterial",0))
        table.insert(allMatsUsages, m:getField("bottomMaterial",0))
        if not matsInObjects['MeshRoads'] then matsInObjects['MeshRoads'] = {} end
        table.insert(matsInObjects['MeshRoads'], m:getField("topMaterial",0))
        table.insert(matsInObjects['MeshRoads'], m:getField("sideMaterial",0))
        table.insert(matsInObjects['MeshRoads'], m:getField("bottomMaterial",0))
      end
    end
    job.progress = 60
    job.sleep(0.001)
    log('I', '', 'Checking DecalData' )
    local meshNames8 = scenetree.findClassObjects('DecalData')
    for _,v in pairs(meshNames8) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "DecalData object broken "..dumps(v))
      else
        mats[m:getField("Material",0)] = true
        table.insert(allMatsUsages, m:getField("Material",0))
        if not matsInObjects['DecalData'] then matsInObjects['DecalData'] = {} end
        table.insert(matsInObjects['DecalData'], m:getField("Material",0))
      end
    end
    job.progress = 65
    job.sleep(0.001)
    if abort(job) then return end
    for k,_ in pairs(mats) do
      job.yield()
      local mat = scenetree.findObject(k)
      local matSizeCheck = {}
      if mat and mat.___type == "class<Material>" then
        local texfields = getMaterialTexFields(mat)
        local matSize = 0
        local matName = mat:getFileName()
        local totalSizeCheck = {}
        if texfields then
          for _,h in pairs(texfields) do
            local file = h
            if file:find(".color.png") or file:find(".data.png") or file:find(".normal.png") then
              if FS:fileExists(file:gsub('.png', '.dds')) then
                file = file:gsub('.png', '.dds')
              elseif FS:fileExists('/temp/'..file:gsub('.png', '.dds')) then
                file = '/temp/'..file:gsub('.png', '.dds')
              end
            end
            if FS:fileExists(file) then
              local fileData = FS:stat(file)
              if matSizeCheck[file] ~= true then
                matSizeCheck[file] = true
                matSize = matSize + fileData.filesize
              end
              if totalSizeCheck[file] ~= true then
                totalSizeCheck[file] = true
                sizeTotal = sizeTotal + fileData.filesize
              end
            elseif matName and not FS:fileExists(file) then
              local dir = path.splitWithoutExt(matName)
              local d, base, ext = path.splitWithoutExt(matName)
              if d and base and FS:fileExists(d..file) then
                local fileData = FS:stat(d..file)
                if matSizeCheck[d..file] ~= true then
                  matSizeCheck[d..file] = true
                  matSize = matSize + fileData.filesize
                end
                if totalSizeCheck[d..file] ~= true then
                  totalSizeCheck[d..file] = true
                  sizeTotal = sizeTotal + fileData.filesize
                end
              end
            else
              log('W', '', 'File not found '..file )
            end
          end
        end
        local countMat = 0
        for _,h in pairs(allMatsUsages) do
          if h == k then countMat = countMat + 1 end
        end
        mats[k] = {matSize, countMat}
      end
    end
    job.progress = 85
    job.sleep(0.001)
    for k,v in pairs(mats) do
      job.yield()
      if v == true or v == false then
        mats[k] = nil
      end
    end
    for k,v in pairs(mats) do
      job.yield()
      table.insert(shapes, {k.."  used: "..tostring(v[2]).." times. Textures memory usage: "..string.format("%.2f", v[1]/1048576).." MB", v[1]})
      countduplicate = countduplicate + 1
    end
    table.sort(shapes, function(a,b) return tonumber(a[2]) > tonumber(b[2]) end)
    for k,v in pairs(shapes) do
      shapes[k] = v[1]
    end
    sizeTotal = string.format("%.2f", sizeTotal/1048576)
    for k,v in pairs(matsInObjects) do
      if (luaType(v) == "table") then
        for _,p in pairs(v) do
          if not usages[p] then usages[p] = {} end
          if not tableContains(usages[p], k) then table.insert(usages[p], k) end
        end
      end
    end
    job.progress = 100
    job.sleep(0.001)
    isDone = 1
  end
  local data = {type, countduplicate, sizeTotal, shapes, isDone, usages}
  extensions.editor_resourceChecker.jobData(3, data)
end
local function checkUsedMats(levelname, removal)
  checkUsedMatsworkJob = extensions.core_jobsystem.create(checkUsedMatswork, 1, levelname)
end

local checkColDataworkJob
local function checkColDatawork(job, levelname)
  local shapes = {}
  local type = 9
  local isDone
  local polyStats = {0, 0, 0}
  local countduplicate = 0
  job.progress = 0
  job.sleep(0.001)
  job.stop = nil
  if not levelname then
    log('E', '', 'There is no level name' )
    isDone = 2
  else
    log('I', '', 'Checking for used colmeshes' )
    log('I', '', 'Checking Prefabs' )
    job.progress = 5
    local staticInstances = {}
    local prefabs = {}
    local prefabInstances = scenetree.findClassObjects('Prefab')
    for _,v in pairs(prefabInstances) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "Prefab object broken "..dumps(v))
      else
        if m:getField('filename',0) then
          table.insert(prefabs, m:getField('filename',0))
        end
      end
    end
    for _, fn in pairs(prefabs) do
      if abort(job) then return end
      job.yield()
      if FS:fileSize(fn) > 0 then
        if string.endswith(fn, 'prefab.json') then
          log('I', '', 'Loading json prefab file '..fn )
          local f = io.open(fn, "r")
          for line in f:lines() do
            job.yield()
            local data = json.decode(line)
            if data.shapeName then
              if not staticInstances[data.shapeName] then
                staticInstances[data.shapeName] = {count = 0, collision = {}, ColPolygons = 0, VisPolygons = 0}
              end
              staticInstances[data.shapeName].count = staticInstances[data.shapeName].count + 1
              if not data.collisionType then
                table.insert(staticInstances[data.shapeName].collision, 'Collision Mesh')
              else
                table.insert(staticInstances[data.shapeName].collision, data.collisionType)
              end
            end
          end
          f:close()
        end
      end
    end
    log('I', '', 'Checking Forest Object' )
    local forestObject = nil
    if core_forest and core_forest.getForestObject() then
      forestObject = core_forest.getForestObject()
    end
    job.progress = 10
    job.sleep(0.001)
    if forestObject then
      job.yield()
      for _,v in pairs(forestObject:getData():getItems()) do
        if not staticInstances[v:getData():getShapeFile()] then
          staticInstances[v:getData():getShapeFile()] = {count = 0, collision = {}, ColPolygons = 0, VisPolygons = 0}
        end
        staticInstances[v:getData():getShapeFile()].count = staticInstances[v:getData():getShapeFile()].count + 1
        table.insert(staticInstances[v:getData():getShapeFile()].collision, 'Collision Mesh')
      end
    end
    job.progress = 15
    job.sleep(0.001)
    log('I', '', 'Checking TSStatics' )
    local meshNames = scenetree.findClassObjects('TSStatic')
    for _,v in pairs(meshNames) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "TSStatic object broken "..dumps(v))
      else
        if not staticInstances[m:getModelFile()] then
          staticInstances[m:getModelFile()] = {count = 0, collision = {}, ColPolygons = 0, VisPolygons = 0}
        end
        staticInstances[m:getModelFile()].count = staticInstances[m:getModelFile()].count + 1
        table.insert(staticInstances[m:getModelFile()].collision, m:getField('collisionType',0))
      end
    end
    for k,v in pairs(staticInstances) do
      if abort(job) then return end
      job.yield()
      if FS:fileExists(k) then
        local shapeLoader = ShapePreview()
        shapeLoader:setObjectModel(k)
        shapeLoader.mFixedDetail = true
        shapeLoader:setCurrentDetail(0)
        shapeLoader:renderWorld(RectI(0,0,256,256))
        staticInstances[k].ColPolygons = shapeLoader.mColPolys
        staticInstances[k].VisPolygons = shapeLoader.mDetailPolys
        shapeLoader:clearShape()
      end
    end
    for k,v in pairs(staticInstances) do
      job.yield()
      local colMeshInst, visMeshInst = 0, 0
      if v and v.ColPolygons > 0 then
        for _,c in pairs(v.collision) do
          if c == "Collision Mesh" then colMeshInst = colMeshInst + 1 end
        end
      end
      if v and v.VisPolygons > 0 then
        for _,c in pairs(v.collision) do
          if (c == "Visible Mesh" or c == "Visible Mesh Final")  then visMeshInst = visMeshInst + 1 end
        end
      end
      local slow = visMeshInst > 0
      local colMeshTotSize = colMeshInst*v.ColPolygons
      local visMeshTotSize = visMeshInst*v.VisPolygons
      local totalColSize = colMeshTotSize+visMeshTotSize
      local totalCount = visMeshInst+colMeshInst
      if slow then
        table.insert(shapes, {k.."   used: "..totalCount.." times. ColPolys: "..v.ColPolygons..". Visible Mesh ColPolys: "..v.VisPolygons..". Total ColPolys: "..totalColSize..". Warning: This mesh is using Visible Mesh Collisions which might be cause performance issues", totalColSize})
      else
        table.insert(shapes, {k.."   used: "..totalCount.." times. ColPolys: "..v.ColPolygons..". Total ColPolys: "..totalColSize, totalColSize})
      end
      polyStats[1] = polyStats[1] + totalColSize
      polyStats[2] = polyStats[2] + visMeshTotSize
      polyStats[3] = polyStats[3] + visMeshInst
      countduplicate = countduplicate + totalCount
    end
    table.sort(shapes, function(a,b) return tonumber(a[2]) > tonumber(b[2]) end)
    for k,v in pairs(shapes) do
      shapes[k] = v[1]
    end
    job.progress = 100
    job.sleep(0.001)
    isDone = 1
  end
  local data = {type, countduplicate, polyStats, shapes, isDone}
  extensions.editor_resourceChecker.jobData(3, data)
end
local function checkColData(levelname, removal)
  checkColDataworkJob = extensions.core_jobsystem.create(checkColDatawork, 1, levelname)
end

local shapestoRemove = {}
local checkUnusedModelsworkJob
local function checkUnusedModelswork(job, levelname, removal)
  local type = 5
  local isDone
  local countduplicate = 0
  local unused = {}
  local models = {}
  local shapes = {}
  local forestShapes = {}
  local size = 0
  job.progress = 0
  job.stop = nil
  job.sleep(0.001)
  if not levelname then
    log('E', '', 'There is no level name' )
    isDone = 2
  else
    log('I', '', 'Checking for unused models' )
    log('I', '', 'Checking Prefabs' )
    job.progress = 5
    local prefabs = FS:findFiles("/levels/"..levelname.."/", "*.prefab\t*.prefab.json", -1, true, false)
    local missionPrefabs = FS:findFiles("/gameplay/missions/"..levelname.."/", "*.prefab\t*.prefab.json", -1, true, false)
    arrayConcat(prefabs, missionPrefabs)
    for _, fn in ipairs(prefabs) do
      if abort(job) then return end
      job.yield()
      if FS:fileSize(fn) > 0 then
        if string.endswith(fn, 'prefab') then
          log('I', '', 'Loading ts prefab file '..fn )
          local f = io.open(fn, "r")
          if f then
            for line in f:lines() do
              job.yield()
              if line:match('shapeName') then
                line = line:gsub('shapeName', ''):gsub('"', ""):gsub(' ', ""):gsub(';', ""):gsub('=', "")
                models[line] = true
              end
            end
            f:close()
          end
        elseif string.endswith(fn, 'prefab.json') then
          log('I', '', 'Loading json prefab file '..fn )
          local f = io.open(fn, "r")
          for line in f:lines() do
            job.yield()
            local data = json.decode(line)
            if data.shapeName then
              models[data.shapeName] = true
            end
          end
          f:close()
        end
      end
    end
    job.progress = 15
    job.sleep(0.001)
    log('I', '', 'Checking TSStatics' )
    local meshNames = scenetree.findClassObjects('TSStatic')
    for _,v in pairs(meshNames) do
      if abort(job) then return end
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "TSStatic object broken "..dumps(v))
      else
        models[m:getField("shapeName",0)] = true
      end
    end
    job.progress = 25
    job.sleep(0.001)
    log('I', '', 'Checking ForestItemData' )
    local meshNames2 = scenetree.findClassObjects('ForestItemData')
    local forestModels = {}
    for _,v in pairs(meshNames2) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "ForestItem object broken "..dumps(v))
      else
        local i = m:getField("internalName",0)
        if not i then log("E", "", "ForestItem object broken")
        else
          forestModels[i] = m:getField("shapeFile",0)
        end
      end
    end
    job.progress = 45
    job.sleep(0.001)
    log('I', '', 'Checking Forest Folder' )
    local forestInternals = {}
    local forestFiles = FS:findFiles("/levels/"..levelname.."/forest/", "*forest4.json", -1, true, false)
    for _,v in pairs(forestFiles) do
      job.yield()
      if FS:fileSize(v) > 0 then
        local dir, basefilename = path.splitWithoutExt(v)
        forestInternals[basefilename:gsub('.forest4', '')] = true
      end
    end
    job.progress = 50
    job.sleep(0.001)
    log('I', '', 'Checking GroundCovers' )
    local meshNames3 = scenetree.findClassObjects('GroundCover')
    for _,v in pairs(meshNames3) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "GroundCover object broken "..dumps(v))
      else
        local idx = 0
        for i = 1, 8 do
          local val = m:getField("shapeFilename", idx)
          if val then models[val] = true end
          idx = idx + 1
        end
      end
    end
    job.progress = 55
    job.sleep(0.001)
    for k,v in pairs(forestModels) do
      job.yield()
      if forestInternals[k] then
        models[v] = true
      end
    end
    local modelsNoExt = {}
    job.progress = 60
    job.sleep(0.001)
    for k,_ in pairs(models) do
      job.yield()
      local dir, basefilename, ext = path.splitWithoutExt(k)
      if basefilename then
        basefilename = string.lower(basefilename)
        modelsNoExt[basefilename] = true
      end
    end
    local tempMdl = {}
    for k,_ in pairs(models) do
      job.yield()
      k = string.lower(k)
      if not k:match '^/' then
        k = '/'..k
      end
      tempMdl[k] = true
    end
    models = tempMdl
    job.progress = 65
    local meshFiles = FS:findFiles("/levels/"..levelname.."/", "*.dae\t*.dts\t*.cdae", -1, true, false)
    for _,v in pairs(meshFiles) do
      job.yield()
      local dir, basefilename, ext = path.splitWithoutExt(v)
      if models[string.lower(v)] then
      elseif ext == "cdae" and basefilename and modelsNoExt[string.lower(basefilename)] then
      else
        log('I', '', 'Found unused model '..v )
        unused[v] = true
      end
    end
    if abort(job) then return end
    job.progress = 75
    for _,v in pairs(forestModels) do
      forestShapes[string.lower(v)] = true
    end
    job.sleep(0.001)
    for k,_ in pairs(unused) do
      job.yield()
      if forestShapes[string.lower(k)] then
        table.insert(shapes, k.."   Warning: This is an active forest item, but not used in the level")
      else
        table.insert(shapes, k)
      end
      local fsize = safeFileSize(k)
      size = size + fsize
      countduplicate = countduplicate + 1
    end
    table.sort(shapes, function(a,b) return string.upper(a) < string.upper(b) end)
    job.progress = 100
    job.sleep(0.001)
    isDone = 1
    size = string.format("%.2f", size/1048576)
  end
  local data = {type, countduplicate, size, shapes, isDone}
  if removal == 1 then
    local toRemove = {}
    for k,_ in pairs(unused) do
      job.yield()
      if forestShapes[string.lower(k)] then
        table.insert(toRemove, k.." /levels/"..levelname.."/art/forest/managedItemData.json")
      else
        table.insert(toRemove, k)
      end
    end
    M.shapestoRemove = toRemove
  else
    extensions.editor_resourceChecker.jobData(3, data)
  end
end
local function checkUnusedModels(levelname, removal)
  checkUnusedModelsworkJob = extensions.core_jobsystem.create(checkUnusedModelswork, 1, levelname, removal)
end

local textoRemove = {}
local unusedTexturesworkJob
local function unusedTextureswork(job, levelname, removal)
  local type = 6
  local isDone
  local countduplicate = 0
  local unused = {}
  local textures = {}
  local shapes = {}
  local size = 0
  job.progress = 0
  job.sleep(0.001)
  job.stop = nil
  if not levelname then
    log('E', '', 'There is no level name' )
    isDone = 2
  else
    log('I', '', 'Checking for unused textures' )
    log('I', '', 'Checking Materials' )
    local meshNames = scenetree.findClassObjects('Material')
    for _,v in pairs(meshNames) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "Material broken "..dumps(v))
      else
        local texfields = getMaterialTexFields(m)
        if texfields then
          for _,vv in pairs(texfields) do
            textures[vv] = true
          end
        end
      end
    end
    job.progress = 10
    job.sleep(0.001)
    log('I', '', 'Checking TerrainMaterials' )
    local meshNames2 = scenetree.findClassObjects('TerrainMaterial')
    for _,v in pairs(meshNames2) do
      if abort(job) then return end
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "TerrainMaterial broken "..dumps(v))
      else
        for k,f in pairs(m:getFields()) do
          job.yield()
          if f["type"] == "filename" then
            textures[m:getField(k,0)] = true
          end
        end
      end
    end
    job.progress = 15
    job.sleep(0.001)
    log('I', '', 'Checking WaterPlanes' )
    local meshNames3 = scenetree.findClassObjects('WaterPlane')
    for _,v in pairs(meshNames3) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "WaterPlane broken "..dumps(v))
      else
        for k,f in pairs(m:getFields()) do
          job.yield()
          if f["type"] == "filename" then
            textures[m:getField(k,0)] = true
          end
        end
      end
    end
    job.progress = 20
    job.sleep(0.001)
    log('I', '', 'Checking WaterBlocks' )
    local meshNames4 = scenetree.findClassObjects('WaterBlock')
    for _,v in pairs(meshNames4) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "WaterBlock broken "..dumps(v))
      else
        for k,f in pairs(m:getFields()) do
          job.yield()
          if f["type"] == "filename" then
            textures[m:getField(k,0)] = true
          end
        end
      end
    end
    job.progress = 25
    job.sleep(0.001)
    log('I', '', 'Checking Rivers' )
    local meshNames5 = scenetree.findClassObjects('River')
    for _,v in pairs(meshNames5) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "River broken "..dumps(v))
      else
        for k,f in pairs(m:getFields()) do
          job.yield()
          if f["type"] == "filename" then
            textures[m:getField(k,0)] = true
          end
        end
      end
    end
    job.progress = 30
    job.sleep(0.001)
    log('I', '', 'Checking CloudLayers' )
    local meshNames6 = scenetree.findClassObjects('CloudLayer')
    for _,v in pairs(meshNames6) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "CloudLayer broken "..dumps(v))
      else
        textures[m:getField("texture",0)] = true
      end
    end
    job.progress = 40
    job.sleep(0.001)
    log('I', '', 'Checking ScatterSkies' )
    local meshNames7 = scenetree.findClassObjects('ScatterSky')
    for _,v in pairs(meshNames7) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "ScatterSky broken "..dumps(v))
      else
        for k,f in pairs(m:getFields()) do
          job.yield()
          if f["type"] == "filename" then
            textures[m:getField(k,0)] = true
          end
        end
      end
    end
    log('I', '', 'Checking Cubemaps' )
    local meshNames8 = scenetree.findClassObjects('CubemapData')
    for _,v in pairs(meshNames8) do
      job.yield()
      local m = scenetree.findObject(v)
      if not m then log("E", "", "Cubemap broken "..dumps(v))
      else
        for k,f in pairs(m:getFields()) do
          job.yield()
          if f["type"] == "filename" then
            textures[m:getField(k,0)] = true
            textures[m:getField(k,1)] = true
            textures[m:getField(k,2)] = true
            textures[m:getField(k,3)] = true
            textures[m:getField(k,4)] = true
            textures[m:getField(k,5)] = true
          end
        end
      end
    end
    log('I', '', 'Checking Info' )
    local meshNames9 = jsonReadFile("/levels/"..levelname.."/info.json")
    if meshNames9 then
      for k,v in pairs(meshNames9) do
        job.yield()
        if k == "previews" then
          for _,t in pairs(v) do
            textures[t] = true
          end
        end
        if k == "spawnPoints" then
          for _,t in pairs(v) do
            for i,m in pairs(t) do
              if i == "preview" then
                textures[m] = true
              end
            end
          end
        end
      end
    end
    job.progress = 50
    job.sleep(0.001)
    local texTemp = {}
    for k,_ in pairs(textures) do
      job.yield()
      if k and k ~= "" then
        local dir, filename, ext = path.split(k)
        if filename then
          local txt = string.lower(filename:gsub('.'..ext, ''))
          texTemp[txt] = true
        end
      end
    end
    if abort(job) then return end
    job.progress = 65
    job.sleep(0.001)
    local texFiles = FS:findFiles("/levels/"..levelname.."/", ".png\t*.dds", -1, true, false)
    local blacklist = {"buslines", "quickrace", "scenarios", "scenarios", "lights", "export", "import", "minimap"}
    for _,v in pairs(texFiles) do
      job.yield()
      for _,b in ipairs(blacklist) do
        if v:find(b) then
          goto skipTex
        end
      end
      local dir, filename, ext = path.split(v)
      local txt = string.lower(filename:gsub('.'..ext, ''))
      if not texTemp[txt] then
        if not (filename:find("ter.depth") or filename:find("minimap") or filename:find("annotation") or filename:find("preview") or filename:find("imposter") or filename:find("spawn")) then
          log('I', '', 'Found unused texture '..v )
          unused[v] = true
        end
      end
      ::skipTex::
    end
    if abort(job) then return end
    job.progress = 75
    job.sleep(0.001)
    for k,_ in pairs(unused) do
      job.yield()
      table.insert(shapes, k)
      local fsize = safeFileSize(k)
      size = size + fsize
      countduplicate = countduplicate + 1
    end
    table.sort(shapes, function(a,b) return string.upper(a) < string.upper(b) end)
    job.progress = 100
    job.sleep(0.001)
    isDone = 1
    size = string.format("%.2f", size/1048576)
  end
  local data = {type, countduplicate, size, shapes, isDone}
  if removal == 1 then
    local toRemove = {}
    for k,_ in pairs(unused) do
      job.yield()
      table.insert(toRemove, k)
    end
    M.textoRemove = toRemove
  else
    extensions.editor_resourceChecker.jobData(3, data)
  end
end
local function unusedTextures(levelname, removal)
  unusedTexturesworkJob = extensions.core_jobsystem.create(unusedTextureswork, 1, levelname, removal)
end

local removeUnusedworkJob
local function removeUnusedwork(job, levelname, item, selected)
  local type = 7
  local count = 0
  local isDone
  local size = 0
  job.progress = 0
  job.sleep(0.001)
  job.stop = nil
  local materialsToRemove = {}
  local shapesToRemove = {}
  local texturesToRemove = {}
  if not levelname then
    log('E', '', 'There is no level name' )
    isDone = 2
  else
    log('I', '', 'Removing unused files' )
    if item == 1 then
      if not tableIsEmpty(selected) then
        for k,_ in pairs(selected) do
          local entry = k:gsub(' ','')
          entry = entry:gsub('in:',';')
          local c = 0
          local location
          local mat
          for w in entry:gmatch("([^;]+)") do
            c = c + 1
            if (c % 2 == 0) then
              location = w
            else
              mat = w
            end
          end
          materialsToRemove[mat] = location
        end
      else
        M.checkUnusedMats(levelname, 1)
        while checkUnusedMatsworkJob.running do
          job.sleep(0.1)
        end
        materialsToRemove = M.matstoRemove
      end
      job.progress = 5
      if not tableIsEmpty(materialsToRemove) then
        for k,v in pairs(materialsToRemove) do
          if string.find(v, levelname) then
            count = count + 1
            log('I', '', 'Removing unused material '..k..' in '..v )
            editor.removeMaterialFromJson(k, v)
          end
        end
      end
      job.progress = 15
    end
    if item == 2 then
      if not tableIsEmpty(selected) then
        for k,_ in pairs(selected) do
          table.insert(shapesToRemove, k)
        end
      else
        M.checkUnusedModels(levelname, 1)
        while checkUnusedModelsworkJob.running do
          job.sleep(0.1)
        end
        shapesToRemove = M.shapestoRemove
      end
      job.progress = 20
      if not tableIsEmpty(shapesToRemove) then
        for _,v in pairs(shapesToRemove) do
          local file
          if string.match(v, "managedItemData.json") then
            file = v:gsub(' /levels/'..levelname..'/art/forest/managedItemData.json','')
            removeFromForestJson(file, "/levels/"..levelname.."/art/forest/managedItemData.json")
          elseif string.match(v, "   Warning: This is an active forest item, but not used in the level") then
            file = v:gsub('   Warning: This is an active forest item, but not used in the level','')
            removeFromForestJson(file, "/levels/"..levelname.."/art/forest/managedItemData.json")
          else
            file = v
          end
          log('I', '', 'Removing unused shape '..file )
          local fsize = safeFileSize(file)
          local rem = FS:removeFile(file)
          if rem == 0 then
            count = count + 1
            size = size + fsize
          elseif rem == -1 then
            local realPath = FS:getUserPath()
            local fileRealPath = FS:getFileRealPath(file)
            local modFilepath = fileRealPath:gsub(realPath, '')
            if FS:fileExists(modFilepath) then
              local rem2 = FS:removeFile(modFilepath)
              if rem2 == 0 then
                count = count + 1
                size = size + fsize
              end
            else
              log('W', '', 'Could not remove shape '..file )
            end
          end
        end
      end
      job.progress = 45
    end
    if item == 3 then
      if not tableIsEmpty(selected) then
        for k,_ in pairs(selected) do
          table.insert(texturesToRemove, k)
        end
      else
        M.unusedTextures(levelname, 1)
        while unusedTexturesworkJob.running do
          job.sleep(0.1)
        end
        texturesToRemove = M.textoRemove
      end
      job.progress = 50
      if not tableIsEmpty(texturesToRemove) then
        for _,v in pairs(texturesToRemove) do
          log('I', '', 'Removing unused texture '..v )
          local fsize = safeFileSize(v)
          local rem = FS:removeFile(v)
          if rem == 0 then
            count = count + 1
            size = size + fsize
          elseif rem == -1 then
            local realPath = FS:getUserPath()
            local fileRealPath = FS:getFileRealPath(v)
            local modFilepath = fileRealPath:gsub(realPath, '')
            if FS:fileExists(modFilepath) then
              local rem2 = FS:removeFile(modFilepath)
              if rem2 == 0 then
                count = count + 1
                size = size + fsize
              end
            else
              log('W', '', 'Could not remove texture '..v )
            end
          end
        end
      end
    end
    job.progress = 100
    job.sleep(0.001)
    isDone = 1
    size = string.format("%.2f", size/1048576)
  end
  local data = {type, count, size, "nothing", isDone}
  extensions.editor_resourceChecker.jobData(3, data)
end
local function removeUnused(levelname, item, selected)
  removeUnusedworkJob = extensions.core_jobsystem.create(removeUnusedwork, 1, levelname, item, selected)
end

local duplicateDataworkJob
local function duplicateDatawork(job, material)
  local verifydata = material
  local duplicatelist = {}
  if not verifydata then
    log('E', '', 'There is no material' )
  else
    log('I', '', 'Searching materials' )
    local matTable = {}
    local maplist = {}
    local materialFiles = {}
    arrayConcat(materialFiles, FS:findFiles("/levels", "*.cs\t*materials.json", -1, true, false))
    arrayConcat(materialFiles, FS:findFiles("/vehicles", "*.cs\t*materials.json", -1, true, false))
    arrayConcat(materialFiles, FS:findFiles("/art", "*.cs\t*materials.json", -1, true, false))
    arrayConcat(materialFiles, FS:findFiles("/core", "*.cs\t*materials.json", -1, true, false))
    matTable = parseMaterialFiles(materialFiles, job)
    if not tableIsEmpty(matTable) then
      log('I', '', 'parsing all materials')
      foreachMaterial(matTable, function(file, key, mat)
        if mat and mat.name then
          if mat.name == verifydata or mat.mapTo == verifydata or key == verifydata then
            if mat.mapTo and mat.mapTo ~= "" and mat.mapTo ~= "unmapped_mat" then maplist[mat.mapTo] = true end
            duplicatelist[file] = duplicatelist[file] or {}
            duplicatelist[file][key] = mat
          end
        elseif mat and not mat.name then
          log('W', '', 'Corrupted or incompatible material found '..file)
        end
        if job then job.yield() end
      end)
      foreachMaterial(matTable, function(file, key, mat)
        if mat and mat.name and mat.mapTo and mat.mapTo ~= "" and mat.mapTo ~= "unmapped_mat" then
          if maplist[mat.mapTo] then
            duplicatelist[file] = duplicatelist[file] or {}
            duplicatelist[file][key] = mat
          end
        elseif mat and not mat.name then
          log('W', '', 'Corrupted or incompatible material found '..file)
        end
        if job then job.yield() end
      end)
    end
    extensions.editor_resourceChecker.updateDuplicateTable(duplicatelist)
  end
end
local function duplicateData(material)
  duplicateDataworkJob = extensions.core_jobsystem.create(duplicateDatawork, 1, material)
end

local removeDummyworkJob
local function removeDummywork(job, convertdata, skipCommon)
  local isDone
  local ok, err = ensureValidPath(convertdata)
  local type = 9
  local matTable = {}
  local resultTable = {}
  local count = 0
  job.progress = 0
  job.sleep(0.001)
  job.stop = nil
  if not ok then
    log('E', '', err )
    isDone = 2
  else
    log('I', '', 'Checking material files' )
    local materialFiles = collectFiles(convertdata, "*materials.json", skipCommon, true)
    job.progress = 20
    job.sleep(0.001)
    local dummyMat = {}
    matTable = parseMaterialFiles(materialFiles, job)
    job.progress = 50
    job.sleep(0.001)
    if not tableIsEmpty(matTable) then
      log('I', '', 'parsing all materials')
      foreachMaterial(matTable, function(file, key, mat)
        if mat and mat.name then
          if not mat.Stages or tableIsEmpty(mat.Stages) or tableIsEmpty(mat.Stages[1]) then
            count = count + 1
            log('I', '', 'Found dummy material: '..mat.name.. ' in: '..file)
            dummyMat[file] = dummyMat[file] or {}
            dummyMat[file][key] = true
          end
        elseif mat and not mat.name then
          log('W', '', 'Corrupted or incompatible material found '..file)
        end
        if job then job.yield() end
        if abort(job) then return end
      end)
      log('I', '', 'Found: '.. count ..' dummy materials')
    end
    job.progress = 85
    job.sleep(0.001)
    for file,mats in pairs(dummyMat) do
      if FS:fileExists(file) then
        local materialFile = jsonReadFile(file) or {}
        for key,_ in pairs(mats) do
          if materialFile[key] then materialFile[key] = nil end
          table.insert(resultTable, key.. ' in: '..file)
        end
        log('I', '', 'Saved materials to '..file )
        jsonWriteFile(file, materialFile, true)
        job.yield()
        if abort(job) then return end
      end
    end
    if abort(job) then return end
    table.sort(resultTable, function(a,b) return string.upper(a) < string.upper(b) end)
    job.progress = 100
    job.sleep(0.001)
    isDone = 1
  end
  local data = {type, count, "dummy", resultTable, isDone}
  extensions.editor_resourceChecker.jobData(2, data)
end
local function removeDummy(convertdata, skipCommon)
  removeDummyworkJob = extensions.core_jobsystem.create(removeDummywork, 1, convertdata, skipCommon)
end

local textureExporterworkJob
local function textureExporterwork(job, convertdata, exportpath)
  local isDone
  local ok, err = ensureValidPath(convertdata)
  local type = 10
  local resultTable = {}
  local count = 0
  job.progress = 0
  job.sleep(0.001)
  if not ok then
    log('E', '', err )
    isDone = 2
  else
    log('I', '', 'Exporting textures to PNG' )
    local meshFiles = FS:findFiles(convertdata, "*.dds", -1, true, false)
    for _, v in ipairs(meshFiles) do
      if job.progress < 98 then job.progress = job.progress + 0.1 end
      job.yield()
      if abort(job) then return end
      if v and not FS:fileExists(v:gsub('.dds', '.png')) then
        local dir, basefilename = path.splitWithoutExt(v)
        local filepathIn = v
        local filepath = exportpath..dir..basefilename..".png"
        if not convertDDSToPNG(filepathIn, filepath) then
          log('E', 'Unable to convert dds to png: ' .. tostring(filepathIn))
        end
        log('I', 'Converted dds to png: ' .. tostring(filepath))
        table.insert(resultTable, filepath)
        count = count + 1
      else
        log('I', 'PNG file already exists: ' .. tostring(v:gsub('.dds', '.png')))
      end
    end
    table.sort(resultTable, function(a,b) return string.upper(a) < string.upper(b) end)
    job.progress = 100
    job.sleep(0.001)
    isDone = 1
  end
  local data = {type, count, "dummy", resultTable, isDone}
  extensions.editor_resourceChecker.jobData(2, data)
end
local function textureExporter(convertdata, exportpath)
  textureExporterworkJob = extensions.core_jobsystem.create(textureExporterwork, 1, convertdata, exportpath)
end

local assetStatsworkJob
local function assetStatswork(job, convertdata)
  local typeId = 10
  local isDone
  job.progress = 0
  job.stop = nil
  job.sleep(0.001)

  if not convertdata then
    log('E','', 'There is no path')
    isDone = 2
  else
    local root = convertdata
    log('I','', 'Scanning assets for stats: '..root)

    job.progress = 5
    job.yield()

    local textures    = FS:findFiles(root, "*.dds\t*.png\t*.jpg\t*.jpeg\t*.tga\t*.bmp", -1, true, false)
    local meshesSrc   = FS:findFiles(root, "*.dae\t*.dts", -1, true, false)
    local meshesCache = FS:findFiles(root, "*.cdae\t*.cached.dts", -1, true, false)
    local terrains    = FS:findFiles(root, "*.ter", -1, true, false)
    local audio       = FS:findFiles(root, "*.bank\t*.ogg\t*.wav\t*.flac\t*.mp3", -1, true, false)
    local datablocks  = FS:findFiles(root, "*.cs\t*.json\t*.jbeam", -1, true, false)
    local allFiles    = FS:findFiles(root, "*", -1, true, false)

    job.progress = 15
    job.yield()

    local texCnt,       texBytes       = sumFilesize(textures)
    local meshSrcCnt,   meshSrcBytes   = sumFilesize(meshesSrc)
    local meshCacheCnt, meshCacheBytes = sumFilesize(meshesCache)
    local terCnt,       terBytes       = sumFilesize(terrains)
    local audCnt,       audBytes       = sumFilesize(audio)
    local dbCnt,        dbBytes        = sumFilesize(datablocks)
    local _,            allBytes       = sumFilesize(allFiles)

    local knownBytes = texBytes + meshSrcBytes + meshCacheBytes + terBytes + audBytes + dbBytes
    local otherBytes = math.max(0, allBytes - knownBytes)

    job.progress = 35
    job.yield()

    local function fillSet(list)
      local s = {}
      for _, p in ipairs(list or {}) do s[p] = true end
      return s
    end

    local texSet       = fillSet(textures)
    local meshSrcSet   = fillSet(meshesSrc)
    local meshCacheSet = fillSet(meshesCache)
    local terSet       = fillSet(terrains)
    local audSet       = fillSet(audio)
    local dbSet        = fillSet(datablocks)

    local otherFiles = {}
    for _, p in ipairs(allFiles or {}) do
      if not (texSet[p] or meshSrcSet[p] or meshCacheSet[p] or terSet[p] or audSet[p] or dbSet[p]) then
        otherFiles[#otherFiles+1] = p
      end
    end

    local function listWithSizes(files)
      local t = {}
      for _, p in ipairs(files or {}) do
        if abort(job) then return {} end
        job.yield()
        local sz = safeFileSize(p) or 0
        t[#t+1] = {path = p, bytes = sz}
      end
      table.sort(t, function(a,b) return (a.bytes or 0) > (b.bytes or 0) end)
      return t
    end

    local texturesL    = listWithSizes(textures)
    local meshSrcL     = listWithSizes(meshesSrc)
    local meshCacheL   = listWithSizes(meshesCache)
    local terrainL     = listWithSizes(terrains)
    local audioL       = listWithSizes(audio)
    local datablocksL  = listWithSizes(datablocks)
    local otherL       = listWithSizes(otherFiles)

    local allFilesSized = {}
    local function appendAll(lst) for _,it in ipairs(lst or {}) do allFilesSized[#allFilesSized+1] = it end end
    appendAll(texturesL); appendAll(meshSrcL); appendAll(meshCacheL)
    appendAll(terrainL);  appendAll(audioL);  appendAll(datablocksL); appendAll(otherL)

    local function countClass(cls)
      local list = scenetree.findClassObjects(cls)
      return list and #list or 0
    end

    local function getForestData()
      local list
      if core_forest.getForestObject() then
        list = core_forest.getForestObject():getData():getItems()
      end
      return list and #list or 0
    end

    local sceneCounts = {
      TSStatic     = countClass('TSStatic'),
      ForestItems  = getForestData(),
      TerrainBlock = countClass('TerrainBlock'),
      DecalRoad    = countClass('DecalRoad'),
      MeshRoad     = countClass('MeshRoad'),
      PointLight   = countClass('PointLight'),
      SpotLight    = countClass('SpotLight'),
      SFXEmitter   = countClass('SFXEmitter'),
      SFXSpace     = countClass('SFXSpace'),
    }

    job.progress = 55
    job.yield()

    local usedTexBytes = 0
    local usedMeshBytes = 0

    local staticFiles = {}
    local prefabModels = {}
    local prefabs = {}
    local prefabInstances = scenetree.findClassObjects('Prefab')
    for _,v in pairs(prefabInstances) do
      if abort(job) then return end
      job.yield()
      local m = scenetree.findObject(v)
      if m and m:getField('filename',0) and FS:fileSize(m:getField('filename',0)) > 0 then
        table.insert(prefabs, m:getField('filename',0))
      end
    end
    for _, fn in ipairs(prefabs) do
      if abort(job) then return end
      job.yield()
      if string.endswith(fn, 'prefab.json') then
        local f = io.open(fn, "r")
        if f then
          for line in f:lines() do
            local data = json.decode(line)
            if data and data.shapeName then
              prefabModels[data.shapeName] = true
            end
            if abort(job) then break end
          end
          f:close()
        end
      end
    end
    local tsList = scenetree.findClassObjects('TSStatic') or {}
    for _,name in ipairs(tsList) do
      if abort(job) then return end
      job.yield()
      local o = scenetree.findObject(name)
      if o and o.getModelFile then
        staticFiles[o:getModelFile()] = true
      end
    end
    local uniqueModels = {}
    for k,_ in pairs(prefabModels) do uniqueModels[k] = true end
    for k,_ in pairs(staticFiles)  do uniqueModels[k] = true end

    local seen = {}
    for k,_ in pairs(uniqueModels) do
      if abort(job) then return end
      job.yield()
      local cache = nil
      if FS:fileExists(k:gsub('.dae','.cdae')) then cache = k:gsub('.dae','.cdae')
      elseif FS:fileExists(k:gsub('.dts','.cached.dts')) then cache = k:gsub('.dts','.cached.dts')
      elseif FS:fileExists('/temp/'..k:gsub('.dae','.cdae')) then cache = '/temp/'..k:gsub('.dae','.cdae')
      elseif FS:fileExists('/temp/'..k:gsub('.dts','.cached.dts')) then cache = '/temp/'..k:gsub('.dts','.cached.dts')
      end
      local f = cache or k
      if not seen[f] then
        seen[f] = true
        usedMeshBytes = usedMeshBytes + safeFileSize(f)
      end
    end


    local matsUsed = {}
    local function addFieldMaterials(className, fields)
      local list = scenetree.findClassObjects(className) or {}
      for _,name in ipairs(list) do
        if abort(job) then return end
        job.yield()
        local o = scenetree.findObject(name)
        if o then
          for _,fld in ipairs(fields) do
            local v = o:getField(fld,0)
            if v and v ~= "" then matsUsed[v] = true end
          end
        end
      end
    end

    local tsList = scenetree.findClassObjects('TSStatic') or {}
    for _,name in ipairs(tsList) do
      if abort(job) then return end
      job.yield()
      local o = scenetree.findObject(name)
      if o and o.getMaterialNames then
        local names = o:getMaterialNames()
        if type(names) == "table" then
          for _,n in pairs(names) do matsUsed[n] = true end
        end
      end
    end
    local tbList = scenetree.findClassObjects('TerrainBlock') or {}
    for _,name in ipairs(tbList) do
      if abort(job) then return end
      job.yield()
      local o = scenetree.findObject(name)
      if o and o.getMaterials then
        for _,tm in pairs(o:getMaterials()) do
          matsUsed[tm:getInternalName()] = true
        end
      end
    end
    addFieldMaterials('GroundPlane', {'Material'})
    addFieldMaterials('GroundCover', {'Material'})
    addFieldMaterials('DecalRoad', {'Material'})
    local mr = scenetree.findClassObjects('MeshRoad') or {}
    for _,name in ipairs(mr) do
      if abort(job) then return end
      job.yield()
      local o = scenetree.findObject(name)
      if o then
        matsUsed[o:getField('topMaterial',0)]    = true
        matsUsed[o:getField('sideMaterial',0)]   = true
        matsUsed[o:getField('bottomMaterial',0)] = true
      end
    end

    local seenTex = {}
    for matName,_ in pairs(matsUsed) do
      if abort(job) then return end
      job.yield()
      local mat = scenetree.findObject(matName)
      if mat and mat.___type == "class<Material>" then
        local texfields = M.getMaterialTexFields(mat)
        if texfields then
          for _,file in pairs(texfields) do
            local f = file
            if f:find(".color.png") or f:find(".data.png") or f:find(".normal.png") then
              if FS:fileExists(f:gsub('.png','.dds')) then f = f:gsub('.png','.dds')
              elseif FS:fileExists('/temp/'..f:gsub('.png','.dds')) then f = '/temp/'..f:gsub('.png','.dds') end
            end
            if not seenTex[f] and FS:fileExists(f) then
              seenTex[f] = true
              usedTexBytes = usedTexBytes + safeFileSize(f)
            end
          end
        end
      end
    end

    job.progress = 85
    job.yield()

    local breakdown = {
      textures      = {count = texCnt,       bytes = texBytes,       files = texturesL},
      meshes_source = {count = meshSrcCnt,   bytes = meshSrcBytes,   files = meshSrcL},
      meshes_cache  = {count = meshCacheCnt, bytes = meshCacheBytes, files = meshCacheL},
      terrain       = {count = terCnt,       bytes = terBytes,       files = terrainL},
      audio         = {count = audCnt,       bytes = audBytes,       files = audioL},
      datablocks    = {count = dbCnt,        bytes = dbBytes,        files = datablocksL},
      other         = {count = #otherFiles,  bytes = otherBytes,     files = otherL},
    }
    local totals = {
      diskBytes    = allBytes,
      usedTexBytes = usedTexBytes,
      usedMeshBytes= usedMeshBytes
    }

    job.progress = 100
    job.sleep(0.001)
    isDone = 1

    local data = {typeId, breakdown, totals, sceneCounts, isDone, { files = allFilesSized }}
    extensions.editor_resourceChecker.jobData(3, data)
  end
end
local function assetStats(levelname)
  assetStatsworkJob = extensions.core_jobsystem.create(assetStatswork, 1, levelname)
end

--interface
local function getProgress()
  if verifyVersionworkJob and verifyVersionworkJob.running then
    return verifyVersionworkJob.progress
  end
  if verifyDuplicateworkJob and verifyDuplicateworkJob.running then
    return verifyDuplicateworkJob.progress
  end
  if fixPIDworkJob and fixPIDworkJob.running then
    return fixPIDworkJob.progress
  end
  if checkMatTexworkJob and checkMatTexworkJob.running then
    return checkMatTexworkJob.progress
  end
  if checkTexworkJob and checkTexworkJob.running then
    return checkTexworkJob.progress
  end
  if checkmissingMatsworkJob and checkmissingMatsworkJob.running then
    return checkmissingMatsworkJob.progress
  end
  if checkStaticworkJob and checkStaticworkJob.running then
    return checkStaticworkJob.progress
  end
  if checkForestworkJob and checkForestworkJob.running then
    return checkForestworkJob.progress
  end
  if checkTerrainsworkJob and checkTerrainsworkJob.running then
    return checkTerrainsworkJob.progress
  end
  if checkUnusedMatsworkJob and checkUnusedMatsworkJob.running then
    return checkUnusedMatsworkJob.progress
  end
  if checkUsedMatsworkJob and checkUsedMatsworkJob.running then
    return checkUsedMatsworkJob.progress
  end
  if checkUnusedModelsworkJob and checkUnusedModelsworkJob.running then
    return checkUnusedModelsworkJob.progress
  end
  if unusedTexturesworkJob and unusedTexturesworkJob.running then
    return unusedTexturesworkJob.progress
  end
  if checkColDataworkJob and checkColDataworkJob.running then
    return checkColDataworkJob.progress
  end
  if removeUnusedworkJob and removeUnusedworkJob.running then
    return removeUnusedworkJob.progress
  end
  if removeDummyworkJob and removeDummyworkJob.running then
    return removeDummyworkJob.progress
  end
  if textureExporterworkJob and textureExporterworkJob.running then
    return textureExporterworkJob.progress
  end
  if assetStatsworkJob and assetStatsworkJob.running then
    return assetStatsworkJob.progress
  end
end

local function stopProgress()
  if verifyVersionworkJob and verifyVersionworkJob.running then
    verifyVersionworkJob.stop = true
  end
  if verifyDuplicateworkJob and verifyDuplicateworkJob.running then
    verifyDuplicateworkJob.stop = true
  end
  if fixPIDworkJob and fixPIDworkJob.running then
    fixPIDworkJob.stop = true
  end
  if checkMatTexworkJob and checkMatTexworkJob.running then
    checkMatTexworkJob.stop = true
  end
  if checkTexworkJob and checkTexworkJob.running then
    checkTexworkJob.stop = true
  end
  if checkmissingMatsworkJob and checkmissingMatsworkJob.running then
    checkmissingMatsworkJob.stop = true
  end
  if checkStaticworkJob and checkStaticworkJob.running then
    checkStaticworkJob.stop = true
  end
  if checkForestworkJob and checkForestworkJob.running then
    checkForestworkJob.stop = true
  end
  if checkTerrainsworkJob and checkTerrainsworkJob.running then
    checkTerrainsworkJob.stop = true
  end
  if checkUnusedMatsworkJob and checkUnusedMatsworkJob.running then
    checkUnusedMatsworkJob.stop = true
  end
  if checkUsedMatsworkJob and checkUsedMatsworkJob.running then
    checkUsedMatsworkJob.stop = true
  end
  if checkUnusedModelsworkJob and checkUnusedModelsworkJob.running then
    checkUnusedModelsworkJob.stop = true
  end
  if unusedTexturesworkJob and unusedTexturesworkJob.running then
    unusedTexturesworkJob.stop = true
  end
  if checkColDataworkJob and checkColDataworkJob.running then
    checkColDataworkJob.stop = true
  end
  if removeUnusedworkJob and removeUnusedworkJob.running then
    removeUnusedworkJob.stop = true
  end
  if removeDummyworkJob and removeDummyworkJob.running then
    removeDummyworkJob.stop = true
  end
  if textureExporterworkJob and textureExporterworkJob.running then
    textureExporterworkJob.stop = true
  end
  if assetStatsworkJob and assetStatsworkJob.running then
    assetStatsworkJob.stop = true
  end
end

local function onExtensionLoaded()
end

-- interface
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.getSimObjects = getSimObjects
M.resaveMaterial = resaveMaterial
M.powerOfTwo = powerOfTwo
M.removeFromForestJson = removeFromForestJson
M.findDuplicates = findDuplicates
M.getMaterialTexFields = getMaterialTexFields
M.verifyVersion = verifyVersion
M.verifyDuplicate = verifyDuplicate
M.fixPID = fixPID
M.checkMatTex = checkMatTex
M.checkTex = checkTex
M.checkmissingMats = checkmissingMats
M.checkStatic = checkStatic
M.checkForest = checkForest
M.checkTerrains = checkTerrains
M.matstoRemove = matstoRemove
M.checkUnusedMatsworkJob = checkUnusedMatsworkJob
M.checkUnusedMats = checkUnusedMats
M.checkUsedMatsworkJob = checkUsedMatsworkJob
M.checkUsedMats = checkUsedMats
M.shapestoRemove = shapestoRemove
M.checkUnusedModelsworkJob = checkUnusedModelsworkJob
M.checkUnusedModels = checkUnusedModels
M.textoRemove = textoRemove
M.unusedTexturesworkJob = unusedTexturesworkJob
M.unusedTextures = unusedTextures
M.removeUnused = removeUnused
M.checkColDataworkJob = checkColDataworkJob
M.checkColData = checkColData
M.duplicateData = duplicateData
M.duplicateDataworkJob = duplicateDataworkJob
M.removeDummyworkJob = removeDummyworkJob
M.removeDummy = removeDummy
M.textureExporterworkJob = textureExporterworkJob
M.textureExporter = textureExporter
M.assetStats = assetStats
M.getProgress = getProgress
M.stopProgress = stopProgress
return M
