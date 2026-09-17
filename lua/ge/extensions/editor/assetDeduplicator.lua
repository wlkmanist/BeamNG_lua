-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui

local cacheData = {}

local cacheFile = '/temp/assetdeduplicator.cache.json'

local generateCacheJob

local selectedMode = im.IntPtr(0)
local modeString = "File hash comparison\0File name comparison"
local modLink = false

local compareFilesJob

local generateLinksJob

local cacheVersion = 3
local gameVersion = beamng_version

local jobLaunchedThisSession = false

local toolWindowName = 'assetDeduplicator'
local comparePopupId = "compreImagesAssets"

local function countEntries(t)
  local count = 0
  if type(t) ~= "table" then return count end
  for _ in pairs(t) do count = count + 1 end
  return count
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local popupState = {}

local function generateLinks(job, jobData)
  job.linkedFiles = ""
  job.error = ""
  job.active = true
  job.status = 0
  if jobData then
    job.processed = 0
    job.allfiles = 0
    local selectedLinks = jobData.selectedLinks

    if selectedLinks then
      job.allfiles = countEntries(selectedLinks)
      for k,v in pairs(selectedLinks) do
        if job.status == 0 then
          if FS:isLinkFile(k) then
            job.processed = job.processed + 1
            job.linkedFiles = job.linkedFiles..job.processed..': Skipped already linked file '..k..'\n'
          elseif FS:fileExists(k) then
            local linkTable = {}
            linkTable.path = v
            linkTable.type = "normal"
            local linkPath = k
            local rem = FS:removeFile(k)
            if rem ~= 0 then
              local realPath = FS:getUserPath()
              local fileRealPath = FS:getFileRealPath(k)
              local modFilepath = fileRealPath or ""
              if realPath and realPath ~= "" and modFilepath:sub(1, #realPath) == realPath then
                modFilepath = modFilepath:sub(#realPath + 1)
              end
              if FS:fileExists(modFilepath) then
                local rem2 = FS:removeFile(modFilepath)
                if rem2 == 0 then
                  linkPath = modFilepath
                else
                  job.status = 1
                  log('E', '', 'Could not remove '..k )
                  job.error = 'Could not remove '..k..'\nMake sure your mod is unpacked and files are accessible'
                end
              else
                job.status = 1
                log('E', '', 'Could not remove '..k )
                job.error = 'Could not remove '..k..'\nMake sure your mod is unpacked and files are accessible'
              end
            end
            if job.status == 0 then
              jsonWriteFile(linkPath..".link", linkTable, true)
              if FS:isLinkFile(linkPath) or FS:isLinkFile(k) then
                log('I', '', 'Linked '..k..' with '..v )
                job.processed = job.processed + 1
                job.linkedFiles = job.linkedFiles..job.processed..': Linked '..k..' with '..v..'\n'
              else
                job.status = 1
                log('E', '', 'Could not create link '..linkPath..'.link' )
                job.error = 'Could not create link '..linkPath..'.link\nMake sure your mod is unpacked and files are accessible'
              end
            end
          else
            job.status = 1
            log('E', '', 'Could not find '..k )
            job.error = 'Could not find '..k..'\nMake sure your mod is unpacked and files are accessible'
          end
        end
        job.yield()
      end
    end
  end
  job.active = false
  job.finished = true
end

local function drawCompareContent(leftPath, rightPath)
  local availH = 512 * im.uiscale[0]
  local tableFlags = im.TableFlags_SizingStretchProp

  if im.BeginTable("cmp_tbl", 2, tableFlags) then
    im.TableNextColumn()
    local cases = {".dds", ".png", ".bmp", ".jpg", ".jpeg", ".tga"}
    local isTexture = false
    for _,b in pairs(cases) do
      if string.lower(leftPath):find(b) then isTexture = true end
    end
    if leftPath and leftPath ~= "" and leftPath ~= "-" and isTexture then
      local imgL = editor.getTempTextureObj(leftPath)
      if imgL and imgL.size.x > 0 and imgL.size.y > 0 then
        local ratio = imgL.size.y / imgL.size.x
        local colW = availH +10
        local sizey = availH
        local sizex = sizey / ratio
        if sizex > colW then
          sizex = colW
          sizey = sizex * ratio
        end
        im.Image(imgL.tex:getID(), im.ImVec2(sizex, sizey), nil, nil, nil, editor.color.white.Value)
      else
        im.Text("Failed to load")
      end
      im.PushTextWrapPos(); im.TextWrapped(leftPath or "-"); im.PopTextWrapPos()
    else
      im.Text("No image")
    end

    im.TableNextColumn()
    local cases = {".dds", ".png", ".bmp", ".jpg", ".jpeg", ".tga"}
    local isTexture = false
    for _,b in pairs(cases) do
      if string.lower(rightPath):find(b) then isTexture = true end
    end
    if rightPath and rightPath ~= "" and rightPath ~= "-" and isTexture then
      local imgR = editor.getTempTextureObj(rightPath)
      if imgR and imgR.size.x > 0 and imgR.size.y > 0 then
        local ratio = imgR.size.y / imgR.size.x
        local colW = availH +10
        local sizey = availH
        local sizex = sizey / ratio
        if sizex > colW then
          sizex = colW
          sizey = sizex * ratio
        end
        im.Image(imgR.tex:getID(), im.ImVec2(sizex, sizey), nil, nil, nil, editor.color.white.Value)
      else
        im.Text("Failed to load")
      end
      im.PushTextWrapPos(); im.TextWrapped(rightPath or "-"); im.PopTextWrapPos()
    else
      im.Text("No image")
    end

    im.EndTable()
  end
end

local function popUp(name, data)
  local description = data.description or ""
  local matches = data.matches or {}

  local state = popupState[name]
  if not state then
    state = { selection = {}, linkChoice = {}, highlight = nil, previewLeft = nil, previewRight = nil, wantOpenCompare = false }
    popupState[name] = state
  end

  local selection = data.selection or state.selection
  state.selection = selection
  data.selection = selection

  local linkChoice = data.linkChoice or state.linkChoice
  state.linkChoice = linkChoice
  data.linkChoice = linkChoice

  local function chooseLink(entry, origin)
    local hasAsset = entry and entry.assets and entry.assets[1]
    if not hasAsset then
      local chosen = linkChoice[origin]
      if chosen and chosen ~= "" then return chosen end
    end
    if hasAsset then return entry.assets[1] end
    if not hasAsset then
      local hasArt = entry and entry.art and entry.art[1]
      if not hasArt then
        local chosen = linkChoice[origin]
        if chosen and chosen ~= "" then return chosen end
      end
      if hasArt then return entry.art[1] end
    end
    if entry and entry.stock and entry.stock[1] then return entry.stock[1] end
    if entry and entry.mod and entry.mod[1] then return entry.mod[1] end
    return "-"
  end

  local function openPreviewFor(origin, entry)
    state.highlight = origin
    state.previewLeft = origin
    state.previewRight = chooseLink(entry, origin)
    state.wantOpenCompare = true
  end

  local sortedKeys = {}
  for k in pairs(matches) do
    sortedKeys[#sortedKeys + 1] = k
  end
  table.sort(sortedKeys)

  local function rebuildSelectedLinks()
    local selectedLinks = {}
    for i = 1, #sortedKeys do
      local origin = sortedKeys[i]
      if selection[origin] then
        local link = chooseLink(matches[origin], origin)
        if link and link ~= "-" then
          selectedLinks[origin] = link
        end
      end
    end
    data.selectedLinks = selectedLinks
  end

  local function countSelected()
    local n = 0
    for i = 1, #sortedKeys do
      if selection[sortedKeys[i]] then n = n + 1 end
    end
    return n
  end

  local icons = editor.icons
  local iconCheck = icons and icons.check or nil
  local iconClose = icons and icons.close or nil

  if im.BeginPopupModal(name, nil,im.WindowFlags_NoCollapse+im.WindowFlags_NoDocking) then

    im.Text(description)

    if im.Button("Select All") then
      for i = 1, #sortedKeys do selection[sortedKeys[i]] = true end
      rebuildSelectedLinks()
    end
    im.SameLine()
    if im.Button("Clear All") then
      for i = 1, #sortedKeys do selection[sortedKeys[i]] = nil end
      rebuildSelectedLinks()
    end
    im.SameLine()
    im.Text(("Selected: %d"):format(countSelected()))

    local tableFlags = im.TableFlags_Borders
      + im.TableFlags_RowBg
      + im.TableFlags_SizingStretchProp
      + im.TableFlags_Resizable
      + im.TableFlags_ScrollY

    local outerSize = im.ImVec2(im.GetWindowSize().x-(10*im.uiscale[0]), im.GetWindowSize().y-(160*im.uiscale[0]))
    if im.BeginTable("matchesTable", 3, tableFlags, outerSize) then
      im.TableSetupColumn("Sel",      im.TableColumnFlags_WidthFixed, 45)
      im.TableSetupColumn("Original", im.TableColumnFlags_WidthStretch, 0.55)
      im.TableSetupColumn("Link",     im.TableColumnFlags_WidthStretch, 0.45)
      im.TableHeadersRow()

      for i = 1, #sortedKeys do
        local origin = sortedKeys[i]
        local entry = matches[origin]
        local isSelected = selection[origin] and true or false
        local hasAsset = entry.assets and entry.assets[1]
        local hasArt = entry.art and entry.art[1]
        local stock = entry.stock or {}
        local mod = entry.mod or {}

        im.TableNextRow()

        if state.highlight == origin then
          local col
          if editor and editor.color and editor.color.headerHovered and editor.color.headerHovered.Value then
            col = editor.color.headerHovered.Value
          elseif im.GetStyleColorVec4 and im.ColorConvertFloat4ToU32 then
            local v = im.GetStyleColorVec4(im.Col_HeaderHovered)
            col = im.ColorConvertFloat4ToU32(v)
          end
          if col then
            im.TableSetBgColor(im.TableBgTarget_RowBg0, col)
          end
        end

        im.TableSetColumnIndex(0)
        local toggled = false
        if editor and editor.uiIconImageButton and (iconCheck or iconClose) then
          local icon = isSelected and iconCheck or iconClose
          if editor.uiIconImageButton(icon, im.ImVec2(24, 24), nil, nil, nil, "sel_" .. tostring(i) .. "_" .. tostring(name)) then
            toggled = true
          end
        else
          local label = (isSelected and "[x]" or "[ ]") .. "##sel_" .. i
          if im.Selectable1(label, false) then
            toggled = true
          end
        end
        if toggled then
          selection[origin] = not isSelected or nil
          rebuildSelectedLinks()
        end

        im.TableSetColumnIndex(1)
        im.PushTextWrapPos()
        if im.Selectable1(origin .. "##orig_" .. i, state.highlight == origin) then
          openPreviewFor(origin, entry)
        end
        im.PopTextWrapPos()

        im.TableSetColumnIndex(2)
        if hasAsset then
          local assetPath = entry.assets[1]
          im.PushTextWrapPos()
          if im.Selectable1((assetPath or "-") .. "##link_" .. i, state.highlight == origin) then
            openPreviewFor(origin, entry)
          end
          im.PopTextWrapPos()
        elseif hasArt then
          local assetPath = entry.art[1]
          im.PushTextWrapPos()
          if im.Selectable1((assetPath or "-") .. "##link_" .. i, state.highlight == origin) then
            openPreviewFor(origin, entry)
          end
          im.PopTextWrapPos()
        elseif #stock > 1 then
          local current = linkChoice[origin] or stock[1]
          local comboId = "##link_combo_" .. tostring(i)
          if im.BeginCombo(comboId, current) then
            for s = 1, #stock do
              local opt = stock[s]
              local selected = (opt == current)
              if im.Selectable1(opt, selected) then
                linkChoice[origin] = opt
                current = opt
                rebuildSelectedLinks()
                if state.highlight == origin then
                  state.previewRight = chooseLink(entry, origin)
                end
              end
            end
            im.EndCombo()
          end
          im.SameLine()
          if im.SmallButton("Preview##" .. i) then
            openPreviewFor(origin, entry)
          end
        elseif #mod > 1 then
          local current = linkChoice[origin] or mod[1]
          local comboId = "##link_combo_" .. tostring(i)
          if im.BeginCombo(comboId, current) then
            for s = 1, #mod do
              local opt = mod[s]
              local selected = (opt == current)
              if im.Selectable1(opt, selected) then
                linkChoice[origin] = opt
                current = opt
                rebuildSelectedLinks()
                if state.highlight == origin then
                  state.previewRight = chooseLink(entry, origin)
                end
              end
            end
            im.EndCombo()
          end
          im.SameLine()
          if im.SmallButton("Preview##" .. i) then
            openPreviewFor(origin, entry)
          end
        else
          local link = (#stock == 1) and stock[1] or (#mod == 1) and mod[1] or "-"
          im.PushTextWrapPos()
          if im.Selectable1((link or "-") .. "##link_" .. i, state.highlight == origin) then
            openPreviewFor(origin, entry)
          end
          im.PopTextWrapPos()
        end
      end

      im.EndTable()
    end

    im.Separator()
    im.Text("Warning: This action is not reversible, double check selected file list before proceeding further.")
    if im.Button("Abort") then im.CloseCurrentPopup() end
    im.SameLine()
    if im.Button("Accept") then
      rebuildSelectedLinks()
      local jobData = {}
      jobData.cacheData = cacheData
      jobData.selectedLinks = data.selectedLinks
      jobData.jobLaunchedThisSession = jobLaunchedThisSession
      generateLinksJob = extensions.core_jobsystem.create(generateLinks, 1, jobData)
      im.CloseCurrentPopup()
    end

    if im.SetNextWindowFocus then im.SetNextWindowFocus() end

    if im.BeginPopup(comparePopupId) then
      drawCompareContent(state.previewLeft, state.previewRight)
      im.Separator()
      if im.Button("Close") then im.CloseCurrentPopup() end
      im.EndPopup()
    end

    if state.wantOpenCompare then
      im.OpenPopup(comparePopupId)
      state.wantOpenCompare = false
    end

    im.EndPopup()
  end
end

local exts = "*.jpg\t*.png\t*.dds\t*.dae\t*.cdae\t*.glb\t*.gltf\t*materials.json\t*.asset.json"

local function findCacheFiles(job, root)
  local files = FS:findFiles(root, exts, -1, true, false)
  local cacheFiles = {}
  for _, filename in ipairs(files) do
    if not FS:isLinkFile(filename) then
      cacheFiles[#cacheFiles + 1] = filename
    end
    job.yield()
  end
  return cacheFiles
end

local function queueCacheFiles(job, cacheWork, out, files, wantOfficial)
  job.allfiles = job.allfiles + #files
  if #files > 0 then
    cacheWork[#cacheWork + 1] = {out = out, files = files, wantOfficial = wantOfficial}
  end
end

local function hashAndStore(job, out, filename, wantOfficial)
  job.yield()

  local h = FS:hashFile(filename)
  local sz = FS:fileSize(filename)

  if wantOfficial then
    out[filename] = {h, sz, isOfficialContentVPath(filename)}
  else
    out[filename] = {h, sz}
  end
end

local function scanGroup(job, cacheData, key, roots, wantOfficial, cacheWork)
  if cacheData[key] then return end
  cacheData[key] = {}

  for _, root in ipairs(roots) do
    local files = findCacheFiles(job, root)

    local out = cacheData[key]
    if #roots > 1 or key == "stockLevels" or key == "modLevels" then
      out[root] = out[root] or {}
      out = out[root]
    end

    queueCacheFiles(job, cacheWork, out, files, wantOfficial)
    job.yield()
  end
end

local function generateCache(job, jobData)
  job.active = true
  if not jobData then
    job.active = false
    job.finished = true
    return
  end

  job.processed, job.allfiles = 0, 0
  job.collectingFiles = true

  local cacheData        = jobData.cacheData
  local cacheFile        = jobData.cacheFile
  local currentLevelId   = jobData.currentLevelId
  cacheData.version      = jobData.cacheVersion
  cacheData.gameVersion  = jobData.gameVersion

  local cacheWork = {}

  -- assets/art
  scanGroup(job, cacheData, "assets", {"/assets/"}, true, cacheWork)
  scanGroup(job, cacheData, "art",    {"/art/"},    true, cacheWork)

  local stockRoots, modRoots = {}, {}
  if (not cacheData.stockLevels) or (not cacheData.modLevels) then
    local infoFiles = FS:findFiles("/levels/", "info.json", 1, true, false)
    local stockSet, modSet = {}, {}

    for _, filename in ipairs(infoFiles) do
      local levelRoot = filename:gsub("info.json", "")
      if isOfficialContentVPath(filename) then
        stockSet[levelRoot] = true
      else
        modSet[levelRoot] = true
      end
      job.yield()
    end

    for root in pairs(stockSet) do stockRoots[#stockRoots+1] = root end
    for root in pairs(modSet)   do modRoots[#modRoots+1]   = root end
  end

  if not cacheData.stockLevels then
    cacheData.stockLevels = {}
    for _, root in ipairs(stockRoots) do
      local files = findCacheFiles(job, root)
      local out = {}
      cacheData.stockLevels[root] = out
      queueCacheFiles(job, cacheWork, out, files, true)
      job.yield()
    end
  end

  if not cacheData.modLevels then
    cacheData.modLevels = {}
    for _, root in ipairs(modRoots) do
      local files = findCacheFiles(job, root)
      local out = {}
      cacheData.modLevels[root] = out
      queueCacheFiles(job, cacheWork, out, files, true)
      job.yield()
    end
  end

  -- current level
  if not cacheData.currentLevel then
    cacheData.currentLevel = {}
    cacheData.currentLevel[currentLevelId] = {}
    local root = "/levels/"..currentLevelId.."/"
    local files = findCacheFiles(job, root)
    local out = cacheData.currentLevel[currentLevelId]
    queueCacheFiles(job, cacheWork, out, files, false) -- original didn’t store official flag here
  end

  job.collectingFiles = false
  job.processed = 0
  for _, work in ipairs(cacheWork) do
    for _, fn in ipairs(work.files) do
      hashAndStore(job, work.out, fn, work.wantOfficial)
      job.processed = job.processed + 1
      job.yield()
    end
  end

  jsonWriteFile(cacheFile, cacheData, true)

  job.active = false
  job.finished = true
end

local function compareFiles(job, jobData)
  local matches = {}
  local fileSizeTotal = 0
  local fileCount = 0
  job.active = true
  if jobData then
    job.processed = 0
    job.allfiles = 0
    local cacheData = jobData.cacheData or {}
    local currentLevelId = jobData.currentLevelId
    local mode = tonumber(jobData.mode) or 0
    local modLink = (jobData.modLink ~= false)
    local currentLevelData = (cacheData['currentLevel'] or {})[currentLevelId] or {}
    local assetData = cacheData['assets'] or {}
    local artData = cacheData['art'] or {}
    local stockLevelsData = cacheData['stockLevels'] or {}
    local modLevelsData = cacheData['modLevels'] or {}

    -- optional blacklist by extension (e.g. { "png", ".dds" })
    local extBlacklist = {".imposter.dds",'.imposter_normals.dds'}
    if type(jobData.blacklistExtensions) == "table" then
      for _, ext in ipairs(jobData.blacklistExtensions) do
        if type(ext) == "string" and ext ~= "" then
          local e = ext:lower()
          if e:sub(1,1) ~= "." then e = "." .. e end
          extBlacklist[e] = true
        end
        job.yield()
        job.yield()
        job.yield()
      end
    end
    local function isBlacklisted(path)
      local ext = path:lower():match("^.+(%.[^/%.]+)$")
      return ext and extBlacklist[ext] or false
    end

    local function allowedByModLink(info)
      if modLink then return true end
      local notMod = info and info[3]
      local isMod = (notMod == false)
      return not isMod
    end

    local function getKey(path, info)
      if mode == 1 then
        return (path:match("([^/]+)$") or path):lower()
      else
        return info and info[1]
      end
    end

    local currentLevelRoot
    for p in pairs(currentLevelData) do
      job.yield()
      currentLevelRoot = p:match("^(/levels/[^/]+/)")
      break
    end

    local assetsByKey = {}
    for path, info in pairs(assetData) do
      if not isBlacklisted(path) and allowedByModLink(info) then
        local key = getKey(path, info)
        if key then
          local list = assetsByKey[key]
          if not list then list = {}; assetsByKey[key] = list end
          list[#list + 1] = path
        end
      end
      job.yield()
      job.yield()
      job.yield()
    end

    local artByKey = {}
    for path, info in pairs(artData) do
      if not isBlacklisted(path) and allowedByModLink(info) then
        local key = getKey(path, info)
        if key then
          local list = artByKey[key]
          if not list then list = {}; artByKey[key] = list end
          list[#list + 1] = path
        end
      end
      job.yield()
      job.yield()
      job.yield()
    end

    local stockByKey = {}
    for _, folderTable in pairs(stockLevelsData) do
      if type(folderTable) == "table" then
        for path, info in pairs(folderTable) do
          if not isBlacklisted(path) and allowedByModLink(info) then
            local key = getKey(path, info)
            if key then
              local list = stockByKey[key]
              if not list then list = {}; stockByKey[key] = list end
              list[#list + 1] = path
            end
          end
          job.yield()
          job.yield()
          job.yield()
        end
      end
      job.yield()
      job.yield()
      job.yield()
    end

    local modByKey = {}
    if modLink then
      for _, folderTable in pairs(modLevelsData) do
        if type(folderTable) == "table" then
          for path, info in pairs(folderTable) do
            if not isBlacklisted(path) then
              local key = getKey(path, info)
              if key then
                local list = modByKey[key]
                if not list then list = {}; modByKey[key] = list end
                list[#list + 1] = path
                job.yield()
                job.yield()
              end
            end
            job.yield()
            job.yield()
          end
        end
        job.yield()
        job.yield()
      end
    end

    for path in pairs(currentLevelData) do
      if not isBlacklisted(path) then
        job.allfiles = job.allfiles + 1
        job.yield()
      end
      job.yield()
    end

    for curPath, info in pairs(currentLevelData) do
      if not isBlacklisted(curPath) then
        local key = getKey(curPath, info)
        local size = tonumber(info[2]) or 0

        local assetMatches = key and assetsByKey[key] or nil
        local artMatches = key and artByKey[key] or nil
        local stockMatches = key and stockByKey[key] or nil
        local modMatches = key and modByKey[key] or nil

        if stockMatches and currentLevelRoot then
          local filtered = {}
          for i = 1, #stockMatches do
            local spath = stockMatches[i]
            if spath:sub(1, #currentLevelRoot) ~= currentLevelRoot then
              filtered[#filtered + 1] = spath
            end
            job.yield()
            job.yield()
            job.yield()
          end
          stockMatches = filtered
        end

        if modMatches and currentLevelRoot then
          local filtered = {}
          for i = 1, #modMatches do
            local spath = modMatches[i]
            if spath:sub(1, #currentLevelRoot) ~= currentLevelRoot then
              filtered[#filtered + 1] = spath
            end
            job.yield()
            job.yield()
            job.yield()
          end
          modMatches = filtered
        end

        if (assetMatches and #assetMatches > 0) or (artMatches and #artMatches > 0) or (stockMatches and #stockMatches > 0) or (modMatches and #modMatches > 0) then
          fileCount = fileCount + 1
          fileSizeTotal = fileSizeTotal + size

          local entry = {
            hash = info[1],
            size = size,
            assets = {},
            art = {},
            stock = {},
            mod = {},
          }

          if assetMatches then
            for i = 1, #assetMatches do
              entry.assets[#entry.assets + 1] = assetMatches[i]
              job.yield()
              job.yield()
              job.yield()
            end
          end
          if artMatches then
            for i = 1, #artMatches do
              entry.art[#entry.art + 1] = artMatches[i]
              job.yield()
              job.yield()
              job.yield()
            end
          end
          if stockMatches then
            for i = 1, #stockMatches do
              entry.stock[#entry.stock + 1] = stockMatches[i]
              job.yield()
              job.yield()
              job.yield()
            end
          end
          if modMatches then
            for i = 1, #modMatches do
              entry.mod[#entry.mod + 1] = modMatches[i]
              job.yield()
              job.yield()
              job.yield()
            end
          end

          matches[curPath] = entry
        end
        job.yield()
        job.yield()
        job.processed = job.processed + 1
      end
      job.yield()
      job.yield()
    end
    job.yield()
    job.matches = matches
    job.matchCount = fileCount
    job.matchSize = fileSizeTotal
  end
  job.active = false
  job.finished = true
end

local function invalidateCache()
  if not (generateCacheJob and generateCacheJob.active) then
    if cacheData and cacheData.version then
      if cacheData.version ~= cacheVersion then
        cacheData = {}
        jobLaunchedThisSession = false
      end
    end
    if cacheData and cacheData.gameVersion then
      if cacheData.gameVersion ~= gameVersion then
        cacheData = {}
        jobLaunchedThisSession = false
      end
    end
    if cacheData and not (cacheData.version or cacheData.gameVersion) then
      cacheData = {}
      jobLaunchedThisSession = false
    end
    if getCurrentLevelIdentifier() then
      if not cacheData['currentLevel'] or not cacheData['currentLevel'][getCurrentLevelIdentifier()] then
        cacheData['currentLevel'] = nil
        jobLaunchedThisSession = false
      end
    end
  end
end

local function onEditorGui()
  if editor.beginWindow(toolWindowName, "Asset Deduplicator", im.WindowFlags_AlwaysAutoResize+im.WindowFlags_NoResize+im.WindowFlags_NoDocking) then
    if tableIsEmpty(cacheData) then
      if FS:fileExists(cacheFile) then
        cacheData = jsonReadFile(cacheFile) or {}
      end
    end
    invalidateCache()
    if jobLaunchedThisSession == false and not (generateCacheJob and generateCacheJob.active) then
      local jobData = {}
      jobData.cacheData = cacheData
      jobData.cacheFile = cacheFile
      jobData.currentLevelId = getCurrentLevelIdentifier()
      jobData.cacheVersion = cacheVersion
      jobData.gameVersion = gameVersion
      generateCacheJob = extensions.core_jobsystem.create(generateCache, 1, jobData)
      jobLaunchedThisSession = true
    end
    if generateCacheJob and generateCacheJob.active and generateCacheJob.collectingFiles then
      im.Text("Collecting cache file list...")
    elseif generateCacheJob and generateCacheJob.active and not (generateCacheJob.processed and generateCacheJob.allfiles) then
      im.Text("Generating cache...")
    elseif generateCacheJob and generateCacheJob.active and generateCacheJob.processed and generateCacheJob.allfiles then
      im.Text("Generating cache... ("..generateCacheJob.processed.."/"..generateCacheJob.allfiles..")")
    elseif tableIsEmpty(cacheData) then
      im.Text("Cache is missing")
    elseif not cacheData['currentLevel'] then
      im.Text("Current level cache is missing")
    else
      im.Text("Remove asset duplicates from current level")
      im.Text("To check current asset file size usage open ")
      im.SameLine()
      if im.Button("Resource Checker") then editor.showWindow("resourceChecker") end
      im.Separator()
      if im.Combo2("##modes", selectedMode, modeString) then
        compareFilesJob = nil
        popupState = {}
      end
      if selectedMode[0] == 0 then
        im.Text("Hash-based comparison matches files with identical content\nthere is no risk of asset discrepancies.")
      else
        im.Text("Filename-based comparison matches files by name only\nit may select assets that differ from the original,\nso manual review is required.")
      end
      if im.Button("Run assessment") then
        local jobData = {}
        jobData.cacheData = cacheData
        jobData.currentLevelId = getCurrentLevelIdentifier()
        jobData.modLink = modLink
        jobData.mode = selectedMode[0]
        compareFilesJob = extensions.core_jobsystem.create(compareFiles, 1, jobData)
      end
      im.SameLine()
      local modLinkEnabled = im.BoolPtr(modLink)
      if im.Checkbox("Allow linking with mods", modLinkEnabled) then
        modLink = modLinkEnabled[0]
        compareFilesJob = nil
        popupState = {}
      end
      im.tooltip("Linking with mods might be risky")
      im.Separator()
      if compareFilesJob and compareFilesJob.active and not (compareFilesJob.processed and compareFilesJob.allfiles) then
        im.Text("Assessing files...")
      elseif compareFilesJob and compareFilesJob.active and compareFilesJob.processed and compareFilesJob.allfiles then
        im.Text("Assessing files... ("..compareFilesJob.processed.."/"..compareFilesJob.allfiles..")")
      elseif compareFilesJob and compareFilesJob.finished and compareFilesJob.matchCount and compareFilesJob.matchSize and compareFilesJob.matches then
        im.Text("It's possible to remove "..compareFilesJob.matchCount.." files.\nThis will reduce level file size by "..string.format("%.2f MB", (tonumber(compareFilesJob.matchSize) or 0)/1048576)..".")
        local popupData = {}
        popupData.matches = compareFilesJob.matches
        popupData.currentLevelId = getCurrentLevelIdentifier()
        popupData.description = "Found matches by file hash:"
        popUp("Preview Changes", popupData)
        if im.Button("Preview and apply") then
          im.OpenPopup("Preview Changes")
        end
        im.Separator()
        if generateLinksJob and generateLinksJob.active and not (generateLinksJob.processed and generateLinksJob.allfiles) then
          im.Text("Linking files...")
        elseif generateLinksJob and generateLinksJob.active and generateLinksJob.processed and generateLinksJob.allfiles then
          im.Text("Linking files... ("..generateLinksJob.processed.."/"..generateLinksJob.allfiles..")")
        elseif generateLinksJob and generateLinksJob.finished and generateLinksJob.status and generateLinksJob.linkedFiles and generateLinksJob.error then
          if generateLinksJob.status == 0 then
            im.Text("Successfully linked files")
            if im.BeginPopup('linkingFinished') then
            im.Text("Successfully all linked files: ")
            im.Text(generateLinksJob.linkedFiles)
            im.Separator()
            if im.Button("Close") then
              cacheData['currentLevel'] = nil
              jobLaunchedThisSession = false
              compareFilesJob = nil
              popupState = {}
              generateLinksJob = nil
              im.CloseCurrentPopup()
            end
            im.EndPopup()
            end
            im.OpenPopup('linkingFinished')
          elseif generateLinksJob.status == 1 then
            im.Text("Failed to remove files before linking.\nMake sure your mod is unpacked.")
            if im.BeginPopup('linkingFinished') then
            im.Text("Failed to link files: ")
            im.Text(generateLinksJob.error)
            im.Separator()
            if im.Button("Close") then im.CloseCurrentPopup() generateLinksJob = nil end
            im.EndPopup()
            end
            im.OpenPopup('linkingFinished')
          end
        end
      else
        im.Text("Assessment did not run.")
      end
      im.Separator()
      if im.Button("Reset current level asset cache") then
        cacheData['currentLevel'] = nil
        jobLaunchedThisSession = false
      end
      im.SameLine()
      if im.Button("Deep clean asset cache") then
        cacheData = nil
        jobLaunchedThisSession = false
      end
    end
  end
  editor.endWindow()
end

local function onEditorActivated()

end

local function onEditorDeactivated()

end

local function onEditorInitialized()
  editor.addWindowMenuItem("Asset Deduplicator", onWindowMenuItem, {groupMenuName = 'Assets'})
  editor.registerWindow(toolWindowName, im.ImVec2(500, 300))
end

M.onEditorGui = onEditorGui
M.onWindowMenuItem = onWindowMenuItem
M.onEditorInitialized = onEditorInitialized
M.onEditorActivated = onEditorActivated
M.onEditorDeactivated = onEditorDeactivated

return M
