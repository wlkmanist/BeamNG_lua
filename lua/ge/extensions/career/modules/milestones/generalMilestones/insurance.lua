-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
M.dependencies = {"career_modules_milestones_milestones", "career_modules_insurance"}
local id = "insurance_repair_claims"
local stepsInfo = {1,5,10,20,50}
local milestones
local currMilestone = {}
M.onGeneralMilestonesCollect = function(milestonesList)
  milestones = career_modules_milestones_milestones
  currMilestone = {
    id = id,
    sortIndex = 0,
    filter = {insurance=true, general=true},
    type = "repair_claims",
    maxStep = #stepsInfo,
    icon = "publisher",
    color=milestones.colorGeneralGray,
    getValue = function() return M.getRepairClaimsNumber() end,
    getLabel = function(step, displayValue, target) return "Sometimes, it happens." end,
    getDescription = function(step, displayValue, target) return string.format("Get %d repair claims.", stepsInfo[step]) end,
    getProgressLabel = function(step, current, target) return string.format("%d / %d", current, target) end,
    getTarget = function(step) return step == 0 and 0 or stepsInfo[step] end,
    getRewards = milestones.minorLinear,
  }

  milestones.saveData.general[id] = milestones.saveData.general[id] or {claimedStep = 0, notificationStep = 0}
  table.insert(milestonesList, currMilestone)
end

local function getRepairClaimsNumber()
  local total = 0
  local plHistory = career_modules_insurance.getPlHistory()
  for _, historyData in pairs(plHistory.policyHistory) do
    total = total + #historyData.claims
  end
  return total
end

local function onInsuranceRepairClaim()
  local step = milestones.saveData.general[id].notificationStep + 1
    -- check if milestone is completed
  if currMilestone.maxStep and step > currMilestone.maxStep then return end
  if getRepairClaimsNumber() >= currMilestone.getTarget(step) then
    milestones.milestoneReached(currMilestone.getLabel(step))
    milestones.saveData.general[id].notificationStep = step
  end
end

M.getRepairClaimsNumber = getRepairClaimsNumber
M.onInsuranceRepairClaim = onInsuranceRepairClaim

return M