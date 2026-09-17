-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

local colorToCompleted = {
  ["var(--bng-add-blue-500)"] = "var(--bng-add-blue-700)",
  ["var(--bng-add-green-500)"] = "var(--bng-add-green-700)",
  ["var(--bng-add-red-500)"] = "var(--bng-add-red-700)",
}
local function sortByTimeAndId(a,b)
  if a.time == b.time and a.entryId and b.entryId then
    if type(a.entryId) == "number" and type(b.entryId) == "number" then
      return a.entryId > b.entryId
    else
      return tostring(a.entryId) > tostring(b.entryId)
    end
  else
    return a.time > b.time
  end
end

local claimFunctions = {}
local claimRefreshFunctions = {}
local getMilestones
local function storeClaimFunctions(list)
  table.clear(claimFunctions)
  for i, elem in ipairs(list) do
    elem.claimId = i
    claimFunctions[i] = elem.claimFunction
    claimRefreshFunctions[i] = elem.claimRefreshFunction
  end
end

local function claim(id)
  local claimFunction = claimFunctions[id] or nop
  local claimRefreshFunction = claimRefreshFunctions[id] or nop
  claimFunction()
  local refresh = claimRefreshFunction()
  if refresh then
    claimFunctions[id] = refresh.claimFunction
    claimRefreshFunctions[id] = refresh.claimRefreshFunction
    refresh.claimId = id
  end
  return refresh
end
M.claim = claim

local function claimAllUnclaimed()
  local data = getMilestones()
  local claimed = 0
  for _, milestone in ipairs(data.list or {}) do
    if milestone.claimable and milestone.claimId then
      claim(milestone.claimId)
      claimed = claimed + 1
    end
  end

  getMilestones()
  return {
    claimed = claimed,
    unclaimedMilestonesCount = M.saveData.unclaimedMilestonesCount or 0,
  }
end
M.claimAllUnclaimed = claimAllUnclaimed

function getMilestones(filter)
  local list = { }
  extensions.hook("onGetMilestones", list, filter)
  --table.sort(list, sortByTimeAndId)
  storeClaimFunctions(list)
  local filters = {}
  M.saveData.unclaimedMilestonesCount = 0
  for _, milestone in ipairs(list) do
    milestone.filter = milestone.filter or {missingFilter=true}
    for key, _ in pairs(milestone.filter) do
      filters[key] = true
    end
    if milestone.claimable then
      M.saveData.unclaimedMilestonesCount = M.saveData.unclaimedMilestonesCount + 1
    end
  end
  return {
    list = list,
    filters = tableKeysSorted(filters)
  }
end


local function onGetMilestones(list)

end
M.getMilestones = getMilestones
M.onGetMilestones = onGetMilestones

-- put here so it can eventually be delayed if in a mission, grouped up if multiple...
local function milestoneReached(label)
  if type(label) == "string" then
    guihooks.trigger("toastrMsg", {type="success", title=_tr("ui.career.milestones.notification.reached.title"), msg=label})
  elseif type(label) == "table" then
    guihooks.trigger("toastrMsg", {type="success", title=_tr("ui.career.milestones.notification.reached.title"), msg=core_locales.contextTranslate(label.txt, label.context)})
  end
  M.saveData.unclaimedMilestonesCount = M.saveData.unclaimedMilestonesCount + 1
end
M.milestoneReached = milestoneReached

-- Load / Save
local saveFile = "milestones.json"
M.saveData = {}

local function loadSaveData()
  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not saveSlot then return end

  local data = (savePath and jsonReadFile(savePath .. "/career/"..saveFile)) or {}
  M.saveData = data
  M.saveData.unclaimedMilestonesCount = M.saveData.unclaimedMilestonesCount or 0
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end
  loadSaveData()
end

local function onSaveCurrentProfile(currentSavePath)
  local filePath = currentSavePath .. "/career/" .. saveFile
  career_saveSystem.jsonWriteFileSafe(filePath, M.saveData, true)
end

local function unclaimedMilestonesCount()
  return M.saveData.unclaimedMilestonesCount
end

local function notifyUnclaimedMilestonesCount()
  if M.saveData.unclaimedMilestonesCount > 0 then
    guihooks.trigger("toastrMsg", {
      type="success",
      title=core_locales.contextTranslate("ui.career.milestones.notification.unclaimed.title", {count = M.saveData.unclaimedMilestonesCount}),
      msg=_tr("ui.career.milestones.notification.unclaimed.message")
    })
  end
end

local function onCareerActive(active)
  if not active then return end
  notifyUnclaimedMilestonesCount()
end

M.loadSaveData = loadSaveData
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onExtensionLoaded = onExtensionLoaded


M.unclaimedMilestonesCount = unclaimedMilestonesCount
M.onCareerActive = onCareerActive

-- common reward functions
M.minorLinear = function(step) return {{attributeKey="money",rewardAmount=100*(step+1)}} end
M.majorLinear = function(step) return {{attributeKey="money",rewardAmount=250*(step+1)}} end

M.colorGeneralGray = "var(--bng-cool-gray-700-rgb)"
M.colorMissionBlue = "var(--bng-add-blue-500-rgb)"

M.colorOrange = "var(--bng-orange-500-rgb)"




return M