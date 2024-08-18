-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"career_career"}

-- CareerStatus vue component
local function getCareerStatusData()
  local data = {}
  data.money = career_modules_playerAttributes.getAttributeValue("money")
  data.beamXP = career_modules_playerAttributes.getAttributeValue("beamXP")
  data.bonusStars = career_modules_playerAttributes.getAttributeValue("bonusStars")
  return data
end
M.getCareerStatusData = getCareerStatusData

--CareerSimpleStats vue component
local function getCareerSimpleStats()
  local currentSaveSlot, _ = career_saveSystem.getCurrentSaveSlot()
  local data = {
    saveSlotName = currentSaveSlot,
    branches = {}
  }

  for _, br in pairs(career_branches.getSortedBranches()) do
    if not br.isSkill then
      local branchInfo = {
        name = br.name,
      }
      local attKey = br.attributeKey
      local value = career_modules_playerAttributes.getAttributeValue(attKey)
      local level, _, _, min, max = career_branches.calcBranchLevelFromValue(value, br.id)
      table.insert(data.branches, {
        name = br.name,
        levelLabel = {txt='ui.career.lvlLabel', context={lvl=level}},
        min = min,
        value = value,
        max = max,
      })
    end
  end
  return data
end
M.getCareerSimpleStats = getCareerSimpleStats

-- Career Pause Context Buttons
local careerPauseContextButtonFunctions = {}
local function storeCareerPauseContextButtons(data)
  table.clear(careerPauseContextButtonFunctions)
  for i, btn in ipairs(data.buttons) do
    btn.functionId = i
    careerPauseContextButtonFunctions[i] = btn.fun
  end
end
local function callCareerPauseContextButtons(functionId)
  local fun = careerPauseContextButtonFunctions[functionId]
  if fun then fun() end
end
local function getCareerPauseContextButtons()
  local data = {
    buttons = {
      {
        label = "Log Test",
        icon = "beampXPFull",
        fun = function() dump("Log Test with icon beampXPFull") end
      },
      {
        label = "Bigmap Test",
        icon = "eyeFillOpened",
        fun = function() freeroam_bigMapMode.enterBigMap() end
      },
      {
        label = "Disabled Test",
        icon = "fragile",
        disabled = true,
      }
    }
  }
  storeCareerPauseContextButtons(data)
  return data
end
M.storeCareerPauseContextButtons = storeCareerPauseContextButtons
M.callCareerPauseContextButtons = callCareerPauseContextButtons
M.getCareerPauseContextButtons = getCareerPauseContextButtons

-- Career pause Preview Cards

local function getCareerCurrentLevelName()
  for _, lvl in ipairs(core_levels.getList()) do
    if string.lower(lvl.levelName) == getCurrentLevelIdentifier() then
      return lvl
    end
  end
end
M.getCareerCurrentLevelName = getCareerCurrentLevelName


return M