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

local function getMilestones(filter)
  local list = { }
  extensions.hook("onGetMilestones", list, filter)
  --table.sort(list, sortByTimeAndId)
  storeClaimFunctions(list)
  local filters = {}
  for _, milestone in ipairs(list) do
    milestone.filter = milestone.filter or {missingFilter=true}
    for key, _ in pairs(milestone.filter) do
      filters[key] = true
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

local function doStuff()
  local playerVeh = getPlayerVehicle(0)
  if not playerVeh then return end
  for i=0, be:getObjectCount()-1 do
    local otherVeh = be:getObject(i)
    if otherVeh and (otherVeh:getID() ~= playerVeh:getID()) then
      local bb1 = playerVeh:getSpawnWorldOOBB()
      local bb2 = otherVeh:getSpawnWorldOOBB()
      local dir = (bb2:getCenter() - bb1:getCenter()):normalized() * 15
      otherVeh:applyClusterVelocityScaleAdd(otherVeh:getRefNodeId(), 0, dir.x, dir.y, dir.z)
    end
  end
end

-- put here so it can eventually be delayed if in a mission, grouped up if multiple...
local function milestoneReached(label)
  if type(label) == "string" then
    guihooks.trigger("toastrMsg", {type="success", title="Milestone Reached!", msg=label})
  elseif type(label) == "table" then
    guihooks.trigger("toastrMsg", {type="success", title="Milestone Reached!", msg=label.txt, context=label.context})
  end
end
M.milestoneReached = milestoneReached

-- Load / Save
local saveFile = "milestones.json"
M.saveData = {}

local function loadSaveData()
  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
  if not saveSlot then return end
  local data = (savePath and jsonReadFile(savePath .. "/career/"..saveFile)) or {}
  M.saveData = data
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end
  loadSaveData()
end

local function onSaveCurrentSaveSlot(currentSavePath)
  local filePath = currentSavePath .. "/career/" .. saveFile
  career_saveSystem.jsonWriteFileSafe(filePath, M.saveData, true)
end

M.loadSaveData = loadSaveData
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onExtensionLoaded = onExtensionLoaded


-- common reward functions
M.minorLinear = function(step) return {{attributeKey="money",rewardAmount=100*(step+1)}, {attributeKey="beamXP",rewardAmount=5*(step+1)}} end
M.majorLinear = function(step) return {{attributeKey="money",rewardAmount=250*(step+1)}, {attributeKey="beamXP",rewardAmount=10*(step+1)}} end

M.colorGeneralGray = "var(--bng-cool-gray-700-rgb)"
M.colorMissionBlue = "var(--bng-add-blue-500-rgb)"

M.colorOrange = "var(--bng-orange-500-rgb)"




return M