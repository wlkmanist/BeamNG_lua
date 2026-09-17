-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local Common = require("ge/extensions/ui/pause/providers/routeData/common")

local M = {}
M.dependencies = {
  "career_career",
  "career_saveSystem",
}

local function navigate(routeName)
  if not extensions.ui_router or not extensions.ui_router.navigate then return false end
  local ok, result = pcall(extensions.ui_router.navigate, routeName)
  return ok and result and result.result ~= false
end

local function getUnclaimedMilestonesCount()
  if not career_modules_milestones_milestones or not career_modules_milestones_milestones.unclaimedMilestonesCount then
    return 0
  end
  return career_modules_milestones_milestones.unclaimedMilestonesCount() or 0
end

local function isCareerProgressAvailable()
  local tutorialActive = career_modules_tutorial and career_modules_tutorial.isActive and career_modules_tutorial.isActive()
  if tutorialActive then return false end
  return career_career and career_career.hasBoughtStarterVehicle and career_career.hasBoughtStarterVehicle()
end

local function getHistoryChanges(historyType, limit)
  if not career_modules_playerAttributes then
    return {}
  end
  if historyType == "gameplay" and career_modules_playerAttributes.getGameplayHistory then
    return career_modules_playerAttributes.getGameplayHistory(limit)
  end
  if career_modules_playerAttributes.getFinancialHistory then
    return career_modules_playerAttributes.getFinancialHistory(limit)
  end
  return {}
end

local function getHistoryInfo(historyType)
  if career_modules_playerAttributes and career_modules_playerAttributes.getCareerHistoryInfo then
    return career_modules_playerAttributes.getCareerHistoryInfo(historyType)
  end
  if historyType == "gameplay" then
    return {
      title = "ui.pause.career.gameplayHistory",
    }
  end
  return {
    title = "ui.pause.career.financialHistory",
  }
end

local function buildHistoryButton(historyType)
  local routeName = "pause.career.history." .. historyType
  local labelKey = historyType == "gameplay" and "ui.pause.career.gameplayHistory" or "ui.pause.career.financialHistory"
  local icon = historyType == "gameplay" and "chartBars" or "banknotes"
  return Common.registerPauseButton({
    id = "careerHistory." .. historyType,
    label = _tr(labelKey),
    icon = icon,
    routeTarget = routeName,
    focusSidePanelId = "careerHistory." .. historyType,
    visible = true,
    enabled = true,
    callback = function()
      return navigate(routeName)
    end,
  })
end

local function buildLogbookButton()
  local routeName = "pause.career.history.logbook"
  return Common.registerPauseButton({
    id = "careerHistory.logbook",
    label = _tr("ui.career.logbook.subHeading"),
    icon = "listBig",
    routeTarget = routeName,
    visible = true,
    enabled = true,
    callback = function()
      return navigate(routeName)
    end,
  })
end

local function buildMilestonesButton()
  local routeName = "pause.career.milestones"
  return Common.registerPauseButton({
    id = "careerHistory.milestones",
    label = _tr("ui.career.milestones.title"),
    icon = "catalog03",
    routeTarget = routeName,
    focusSidePanelId = "careerHistory.milestones",
    showIndicator = getUnclaimedMilestonesCount() > 0,
    visible = true,
    enabled = true,
    callback = function()
      return navigate(routeName)
    end,
  })
end

local function buildDomainSidePanelContents()
  local contents = {}
  for _, domainId in ipairs({"apm", "bmra", "logistics", "freestyle"}) do
    contents["careerProgressDomain." .. domainId] = {
      {
        id = "careerProgressDomainInfo." .. domainId,
        type = "component",
        componentName = "ProgressDomainInfo",
        props = {
          domainId = domainId,
        },
      },
    }
  end
  return contents
end

function M.getCareerProgressData(context)
  local mainPanelContent = {}

  table.insert(mainPanelContent, {
    id = "progressDigest",
    type = "component",
    componentName = "ProgressDigest",
  })

  table.insert(mainPanelContent, {
    id = "apmSuggestedMissions",
    type = "component",
    componentName = "ApmSuggestedMissions",
  })

  return {
    mode = context.mode,
    heading = _tr("ui.career.landingPage.name"),
    mainPanelContent = mainPanelContent,
    focusSidePanelContents = buildDomainSidePanelContents(),
  }
end

function M.getCareerHistoryData(context)
  local railActions = {
    buildHistoryButton("financial"),
    buildHistoryButton("gameplay"),
    buildMilestonesButton(),
    buildLogbookButton(),
  }

  return {
    mode = context.mode,
    heading = _tr("ui.pause.career.history"),
    rail = {
      Common.asRailGroup("careerHistory", railActions),
    },
    focusSidePanelContents = {
      ["careerHistory.financial"] = {
        {
          id = "careerHistoryDigest.financial",
          type = "component",
          componentName = "CareerHistoryDigest",
          sideCardClass = "menu-content-card-2--extra-wide",
          props = {
            historyType = "financial",
            entries = getHistoryChanges("financial", 5),
          },
        },
      },
      ["careerHistory.gameplay"] = {
        {
          id = "careerHistoryDigest.gameplay",
          type = "component",
          componentName = "CareerHistoryDigest",
          sideCardClass = "menu-content-card-2--extra-wide",
          props = {
            historyType = "gameplay",
            entries = getHistoryChanges("gameplay", 5),
          },
        },
      },
      ["careerHistory.milestones"] = {
        {
          id = "careerHistoryDigest.milestones",
          type = "component",
          componentName = "MilestoneDigest",
        },
      },
    },
  }
end

function M.getCareerHistoryDetailData(context, historyType)
  local info = getHistoryInfo(historyType)
  return {
    mode = context.mode,
    heading = _tr(info.title or "ui.pause.career.history"),
    mainCardClass = {"menu-content-card-1--no-scroll", "menu-content-card-1--extra-wide"},
    mainPanelContent = {
      {
        id = "careerHistoryFull." .. (historyType or "financial"),
        type = "component",
        componentName = "CareerHistoryDigest",
        props = {
          historyType = historyType,
          entries = getHistoryChanges(historyType),
          full = true,
        },
      },
    },
  }
end

return M
