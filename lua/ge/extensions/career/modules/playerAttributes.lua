-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local dlog = function(m) log("D","",m) end -- set to nop to disable loggin

M.dependencies = {'career_career'}

local attributes
local attributeLog
local baseAttribute = {value = 0, gains = {}, losses = {}}

local function getBranchForAttributeKey(attributeKey)
  for _, branch in ipairs(career_branches.getSortedBranches()) do
    if branch.attributeKey == attributeKey then
      return branch
    end
  end
end

local function getRewardDisplayName(attributeKey)
  if attributeKey == "money" then return "ui.pause.career.historyRewardMoney" end
  if attributeKey == "beamXP" then return "ui.pause.career.historyRewardBeamXp" end
  if attributeKey == "vouchers" then return "ui.pause.career.historyRewardVouchers" end
  if attributeKey == "reputation" then return "ui.pause.career.historyRewardReputation" end

  local branch = getBranchForAttributeKey(attributeKey)
  if branch then
    return {
      txt = "ui.pause.career.historyRewardBranchXp",
      context = {branchName = branch.branchHeading or branch.name},
    }
  end

  return attributeKey
end

local function formatReward(reward)
  if not reward then return nil end
  reward.displayName = reward.displayName or getRewardDisplayName(reward.attributeKey)
  return reward
end

local function init()
  attributeLog = {}
  attributes = {}
  attributes["beamXP"] = deepcopy(baseAttribute)
  attributes["money"] = deepcopy(baseAttribute)
  attributes["vouchers"] = deepcopy(baseAttribute)
  for _, branch in ipairs(career_branches.getSortedBranches()) do
    attributes[branch.attributeKey] = deepcopy(baseAttribute)
    attributes[branch.attributeKey].value = branch.defaultValue or baseAttribute.value
  end
  local modeData = career_career.getCurrentStartingModeData and career_career.getCurrentStartingModeData()
  local initPlayerAttributesFn = modeData and (modeData.initPlayerAttributes or modeData.initiPlayerAttributes)
  if type(initPlayerAttributesFn) == "function" then
    initPlayerAttributesFn(M)
  else
    -- Fallback for undefined/invalid start mode modules.
    M.setAttributes({money = 10000}, {label = "ui.career.attributeLog.startingCapital"})
  end
end

-- reason should be table with label, list of tags
local function addAttributes(change, reason)

  -- make sure a reason exists!
  if not reason then
    reason = {
      label = "ui.career.attributeLog.unknownReason",
      origin = debug.tracesimple()
    }
    log("W","",string.format("Changed attributes '%s' without giving a reason!", table.concat( tableKeysSorted(change), ", ")))
  end

  -- convert tags into LUT
  if not reason.tags then reason.tags = {} end
  reason.tags = tableValuesAsLookupDict(reason.tags)

  -- make statistic
  for attributeName, value in pairs(change) do
    attributes[attributeName] = attributes[attributeName] or deepcopy(baseAttribute)
    local attribute = attributes[attributeName]
    attribute.value = clamp(attribute.value + value, attribute.min or -math.huge, attribute.max or math.huge)
    for tag, en in pairs(reason.tags) do
      if en and value > 0 then
        attribute.gains[tag] = (attribute.gains[tag] or 0) + value
      end
      if en and value < 0 then
        attribute.losses[tag] = (attribute.losses[tag] or 0) + value
      end
    end
    if value > 0 then
      attribute.gains.all = (attribute.gains.all or 0) + value
    end
    if value < 0 then
      attribute.losses.all = (attribute.losses.all or 0) + value
    end

    if attributeName:endswith("Reputation") then
      local orgId = attributeName:sub(1, -11)
      career_career.interactWithOrganization(orgId)
    end
  end

  -- log change for logbook etc
  table.insert(attributeLog, {
    attributeChange = change,
    reason = reason,
    time = os.time()
  })

  -- Always use the internal log system. The attribute log keeps the original
  -- label key/object so UI history can translate it when displayed.
  local logLabel = reason.label
  if type(logLabel) == "table" then
    logLabel = core_locales.translateWithOrWithoutContext(logLabel)
  elseif type(logLabel) == "string" then
    logLabel = _tr(logLabel)
  end
  career_modules_log.addLog(logLabel, "playerAttributes")

  -- notify other systems
  extensions.hook("onPlayerAttributesChanged",change, reason)

  if reason.tags.gameplay and change.money and gameplay_achievement and not career_modules_tutorial.isActive() then
    gameplay_achievement.unlockAchievement("FIRST_ASSIGNMENT")
  end

  if reason.tags.fine and change.money and gameplay_achievement then
    gameplay_achievement.unlockAchievement("PAID_THE_PRICE")
  end
end

local function setAttributes(newValues, reason)
  local ch = {}
  for attributeName, newValue in pairs(newValues) do
    local attribute = attributes[attributeName] or deepcopy(baseAttribute)
    ch[attributeName] = newValues[attributeName] - attribute.value
  end
  M.addAttributes(ch, reason)
end

local function getAttribute(attributeName)
  return attributes[attributeName]
end
local function getAttributeValue(attributeName)
  return (attributes[attributeName] or baseAttribute).value
end

local function getAllAttributes()
  return attributes
end

local function buildGameplayRewards(attributeChange)
  local rewards = {}
  for _, key in ipairs(career_branches.orderAttributeKeysByBranchOrder(tableKeys(attributeChange or {}))) do
    if key:endswith("Reputation") then
      table.insert(rewards, formatReward({attributeKey = "reputation", rewardAmount = attributeChange[key], icon="peopleOutline"}))
    else
      table.insert(rewards, formatReward({attributeKey = key, rewardAmount = attributeChange[key], icon = career_branches.getBranchIcon(key)}))
    end
  end
  return rewards
end

local function getCareerHistoryChanges(historyType, limit)
  local maxEntries = tonumber(limit)
  local rows = {}
  if not attributeLog then return rows end

  for _, change in ipairs(arrayReverse(deepcopy(attributeLog))) do
    local attributeChange = change.attributeChange or {}
    local reason = change.reason or {}
    local rewards
    if historyType == "financial" and attributeChange.money then
      rewards = {
        formatReward({
          attributeKey = "money",
          rewardAmount = attributeChange.money,
        })
      }
    elseif historyType == "gameplay" and reason.tags and reason.tags.gameplay then
      rewards = buildGameplayRewards(attributeChange)
    end

    if rewards and #rewards > 0 then
      table.insert(rows, {
        reason = reason.label or "Unknown Reason",
        time = change.time,
        rewards = rewards,
      })
      if maxEntries and #rows >= maxEntries then
        break
      end
    end
  end

  return rows
end

local function getRecentFinancialChanges(limit)
  return getCareerHistoryChanges("financial", limit or 5)
end

local function getFinancialHistory(limit)
  return getCareerHistoryChanges("financial", limit)
end

local function getGameplayHistory(limit)
  return getCareerHistoryChanges("gameplay", limit)
end

local function getCareerHistoryInfo(historyType)
  if historyType == "gameplay" then
    return {
      title = "ui.pause.career.gameplayHistory",
    }
  end
  return {
    title = "ui.pause.career.financialHistory",
  }
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end
  if not attributes then
    init()
  end

  -- load from saveslot
  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not saveSlot then return end
  local jsonData = (savePath and jsonReadFile(savePath .. "/career/playerAttributes.json")) or {}

  local saveInfo = savePath and jsonReadFile(savePath .. "/info.json")
  if saveInfo and saveInfo.version < 37 then
    -- rename bonusStars to vouchers
    jsonData.vouchers = jsonData.bonusStars
    jsonData.bonusStars = nil
  end

  -- backwards compatibility for old branch names
  local oldAttributeNamesToNewNames = career_branches.oldAttributeNamesToNewNames
  local updatedNames = {}

  for name, data in pairs(jsonData) do
    local mappedName = oldAttributeNamesToNewNames[name] or name
    if oldAttributeNamesToNewNames[name] then
      updatedNames[name] = mappedName
    end
    attributes[mappedName] = attributes[mappedName] or deepcopy(baseAttribute)
    for k,v in pairs(data) do
      attributes[mappedName][k] = v
    end
  end

  attributeLog = (savePath and jsonReadFile(savePath .. "/career/attributeLog.json")) or attributeLog

  -- Update old attribute names in the log to new names for backwards compatibility
  for _, change in ipairs(attributeLog) do
    if change.attributeChange then
      local updatedChanges = {}
      for oldName, value in pairs(change.attributeChange) do
        local newName = oldAttributeNamesToNewNames[oldName] or oldName
        if oldAttributeNamesToNewNames[oldName] then
          updatedNames[oldName] = newName
        end
        updatedChanges[newName] = value
      end
      change.attributeChange = updatedChanges
    end
  end

  -- Log all name updates at once
  if next(updatedNames) then
    local msg = "Updated attribute names:"
    for oldName, newName in pairs(updatedNames) do
      msg = msg .. string.format("\n  %s -> %s", oldName, newName)
    end
    log('I', '', msg)
  end

end

-- this should only be loaded when the career is active
local function onSaveCurrentProfile(currentSavePath)
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/playerAttributes.json", attributes, true)
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/attributeLog.json", attributeLog, true)
end


local function onCareerActive(active)
  if not active then return end
  for orgId, organization in pairs(freeroam_organizations.getOrganizations()) do
    if not attributes[orgId .. "Reputation"] then
      local attribute = deepcopy(baseAttribute)
      attribute.min = career_modules_reputation.getMinimumValue()
      attribute.max = career_modules_reputation.getMaximumValue()
      attributes[orgId .. "Reputation"] = attribute
    end
  end
end

-- logbook integration
local function onLogbookGetEntries(_)
end

M.addAttributes = addAttributes
M.setAttributes = setAttributes
M.getAttribute = getAttribute
M.getAttributeValue = getAttributeValue
M.getAllAttributes = getAllAttributes
M.getRecentFinancialChanges = getRecentFinancialChanges
M.getFinancialHistory = getFinancialHistory
M.getGameplayHistory = getGameplayHistory
M.getCareerHistoryInfo = getCareerHistoryInfo
M.getAttributeLog = function() return attributeLog end

M.logAttributeChange = logAttributeChange
M.onLogbookGetEntries = onLogbookGetEntries
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onExtensionLoaded = onExtensionLoaded
M.onCareerActive = onCareerActive

return M