-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function resolveAssetPath(basePath, assetPath)
  if assetPath == nil then return nil end
  local path = tostring(assetPath)
  if path == "" then return nil end
  if string.sub(path, 1, 1) == "/" then return path end
  return basePath .. path
end

local function readPopupEntryById(id, options)
  options = options or {}
  local root = options.root or "/gameplay/tutorials/pages/"
  local basePath = root .. id .. "/"
  local jsonPath = basePath .. "content.json"
  local htmlPath = basePath .. "content.html"

  local entry = {
    id = id,
    type = "info",
    isPopup = true,
  }

  if FS:fileExists(jsonPath) then
    local data = jsonReadFile(jsonPath) or {}
    if data.title ~= nil then entry.title = _tr(data.title) end
    if data.text ~= nil then entry.text = _tr(data.text) end
    if data.image ~= nil then entry.image = resolveAssetPath(basePath, data.image) end
    if data.aspectRatio ~= nil then entry.aspectRatio = tostring(data.aspectRatio) end
    if data.vueComponent ~= nil then entry.vueComponent = tostring(data.vueComponent) end
    if data.topics ~= nil then entry.topics = data.topics end
    if data.rows ~= nil then
      entry.rows = {}
      for _, row in ipairs(data.rows) do
        local resolved = { text = _tr(row.text) or "" }
        resolved.images = {}
        if row.images ~= nil then
          if type(row.images) == "table" then
            for _, img in ipairs(row.images) do
              table.insert(resolved.images, resolveAssetPath(basePath, tostring(img)))
            end
          else
            table.insert(resolved.images, resolveAssetPath(basePath, tostring(row.images)))
          end
        elseif row.image ~= nil then
          table.insert(resolved.images, resolveAssetPath(basePath, tostring(row.image)))
        end
        table.insert(entry.rows, resolved)
      end
    end
    if data.vueComponent == "DragTimeslipTutorialPopup" then
      entry.slip = options.slip or nil
      if not entry.slip then
        entry.slip = gameplay_drag_dragBridge and gameplay_drag_dragBridge.createTimeslipData() or nil
      end
    end
    if data.vueComponent == "ApmOnboardingPopup" then
      entry.startingMoney = options.startingMoney or options.startMoney or 0
      entry.endMoney = options.endMoney or options.money or 10000
    end
    return entry
  end

  if FS:fileExists(htmlPath) then
    entry.content = readFile(htmlPath):gsub("\r\n","")
    return entry
  end

  return nil
end

local function openPopupEntries(entries, options)
  if not entries or #entries == 0 then return false end
  guihooks.trigger("OpenTutorialPopup", {
    popups = entries,
  })
  return true
end

local function openPopupById(id, options)
  local entry = readPopupEntryById(id, options)
  if not entry then return false end
  return openPopupEntries({ entry }, options)
end

local function openPopupsByIds(ids, options)
  if type(ids) ~= "table" or #ids == 0 then return false end
  local entries = {}
  for _, id in ipairs(ids) do
    local entry = readPopupEntryById(id, options)
    if entry then
      table.insert(entries, entry)
    end
  end
  if #entries == 0 then return false end
  return openPopupEntries(entries, options)
end

local function closeTutorialPopup()
  guihooks.trigger("CloseTutorialPopup")
  return true
end

local function collectPopupIdsFromRoot(root)
  root = root or "/gameplay/tutorials/pages/v2/"
  if string.sub(root, -1) ~= "/" then
    root = root .. "/"
  end

  local files = FS:findFiles(root, "content.json\tcontent.html", -1, true, false) or {}
  local idsByName = {}

  for _, filePath in ipairs(files) do
    local relativePath = filePath
    if string.sub(relativePath, 1, #root) == root then
      relativePath = string.sub(relativePath, #root + 1)
    end
    local id = relativePath:match("^([^/\\]+)/")
    if id and id ~= "" then
      idsByName[id] = true
    end
  end

  local ids = {}
  for id in pairs(idsByName) do
    table.insert(ids, id)
  end
  table.sort(ids)

  return ids, root
end

local function openAllPopupsFromRoot(options)
  options = options or {}
  local ids, root = collectPopupIdsFromRoot(options.root)
  if #ids == 0 then return false end

  local mergedOptions = {}
  for key, value in pairs(options) do
    mergedOptions[key] = value
  end
  mergedOptions.root = root

  return openPopupsByIds(ids, mergedOptions)
end

M.openDrivingAssistsPopup = function(options)
  --guihooks.trigger("OpenTutorialDrivingAssistants", options)
  local entry = {
    id = "drivingAssists",
    title = "Shifting Style Selection",
    vueComponent = "GearboxSelect",
  }
  return openPopupEntries({ entry }, options)
end

M.openOptionalChallengeSelectionPopup = function(options)
  local entry = {
    id = "optionalChallengeSelection",
    title = "Optional Challenge Selection",
    vueComponent = "OptionalChallengeSelect",
  }
  return openPopupEntries({ entry }, options)
end

M.openDragTimeslipTutorialPopup = function(options, additionalIds)
  options = options or {}
  additionalIds = additionalIds or {}


  local entry = readPopupEntryById("v2/dragStripTimeslipIntro")
  if entry then
    entry.slip = slip
  end

  local entries = { entry }
  if additionalIds then
    for _, id in ipairs(additionalIds) do
      local entry = readPopupEntryById(id)
      if entry then
        table.insert(entries, entry)
      end
    end
  end
  return openPopupEntries(entries, options)
end

M.openContractSignPopup = function(options, additionalIds)
  options = options or {}
  local entry = {
    id = options.id or "contractSign",
    title = options.title or "Join the APM Team",
    text = options.text or "Welcome to APM HQ. This is where you will manage your vehicles, take on assignments, and grow your career. Sign up now and get your 10k starting bonus today.",
    vueComponent = "ContractSign",
    contractTitle = options.contractTitle or "APM - Test Driver Agreement",
    contractText = options.contractText or "By signing this agreement, the undersigned accepts the terms of test-driving employment with APM and confirms acceptance of the starting bonus.",
    userName = options.userName or "Unnamed Player",
    money = options.money or 10000,
    image = resolveAssetPath(options.root or "/gameplay/tutorials/pages/v2/", options.image or "hqIntroductionAndContractSign/v2_hqIntroductionAndContractSign_image.jpg"),
  }
  local entries = { entry }
  if additionalIds then
    for _, id in ipairs(additionalIds) do
      local entry = readPopupEntryById(id, options)
      if entry then
        table.insert(entries, entry)
      end
    end
  end
  return openPopupEntries(entries, options)
end

M.showDragTreeStagesPopup = function(options)
  options = options or {}
  local root = options.root or "/gameplay/tutorials/pages/v2/"
  return openPopupsByIds({ "dragStripStageCar", "dragTreeStages", "dragTreeCountdown", "dragStripTimeslipIntro" }, { root = root })
end

M.resolveAssetPath = resolveAssetPath
M.readPopupEntryById = readPopupEntryById
M.openPopupEntries = openPopupEntries
M.openPopupById = openPopupById
M.openPopupsByIds = openPopupsByIds
M.closeTutorialPopup = closeTutorialPopup
M.collectPopupIdsFromRoot = collectPopupIdsFromRoot
M.openAllPopupsFromRoot = openAllPopupsFromRoot

return M
