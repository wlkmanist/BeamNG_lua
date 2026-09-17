-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--- AI Competitors configuration panel (rally editor window).

local im = ui_imgui
local model = require("/lua/ge/extensions/editor/rallyEditor/aiCompetitorsEditorModel")
local aiCompetitorsTexts = require("/lua/ge/extensions/editor/rallyEditor/aiCompetitorsEditorTexts")
local aiCompetitorsPreview = require("/lua/ge/extensions/editor/rallyEditor/aiCompetitorsEditorPreview")
local aiCompetitorsPlot = require("/lua/ge/extensions/editor/rallyEditor/aiCompetitorsEditorPlot")

local logTag = "rallyEditor"

local referenceTimeMinSec = 1.0
local referenceTimeDefaultSec = 100.0

local function pushSectionHeading(text)
  im.PushFont3("cairo_semibold_large")
  im.Text(text)
  im.PopFont()
end

local function pushMutedCaption(text)
  im.TextColored(im.ImVec4(0.65, 0.65, 0.65, 1), text)
end

local function cloneCompetitorListForEditing(sourceList)
  local result = {}
  for index = 1, #sourceList do
    local competitor = sourceList[index]
    result[index] = {
      name = competitor.name,
      skill = competitor.skill,
      consistency = competitor.consistency,
      risk = competitor.risk,
    }
  end
  return result
end

local Panel = {}
Panel.__index = Panel
Panel.windowDescription = aiCompetitorsTexts.windowDescription

function Panel:init()
  self.competitors = {}
  self.ui = model.defaultUiDict()
  self.selectedCompetitorIndex = 1
  self.generalFloatPtrs = {}
  local baseGeneral = model.mergeGeneral(nil)
  for _, fieldName in ipairs(model.generalFieldNames) do
    self.generalFloatPtrs[fieldName] = im.FloatPtr(baseGeneral[fieldName] or 0)
  end
  self.referenceTimePtr = im.FloatPtr(self.ui.default_player_time_sec or referenceTimeDefaultSec)
  self.traitSkillPtr = im.FloatPtr(0.5)
  self.traitConsistencyPtr = im.FloatPtr(0.5)
  self.traitRiskPtr = im.FloatPtr(0.5)
  self:loadFromDisk()
end

function Panel:gatherGeneralTable()
  local general = {}
  for _, fieldName in ipairs(model.generalFieldNames) do
    local ptr = self.generalFloatPtrs[fieldName]
    if ptr then
      general[fieldName] = ptr[0]
    end
  end
  return general
end

function Panel:applyGeneralTable(general)
  for _, fieldName in ipairs(model.generalFieldNames) do
    local ptr = self.generalFloatPtrs[fieldName]
    if ptr and general[fieldName] ~= nil then
      ptr[0] = model.clampParamToSliderRange(fieldName, general[fieldName])
    end
  end
end

function Panel:syncTraitsIntoSelectedCompetitor()
  local competitorCount = #self.competitors
  if competitorCount == 0 then
    return
  end
  local index = self.selectedCompetitorIndex
  if index < 1 or index > competitorCount then
    return
  end
  local competitor = self.competitors[index]
  competitor.skill = self.traitSkillPtr[0]
  competitor.consistency = self.traitConsistencyPtr[0]
  competitor.risk = self.traitRiskPtr[0]
end

function Panel:applySelectedCompetitorToTraitSliders()
  local competitorCount = #self.competitors
  if competitorCount == 0 then
    return
  end
  local index = math.max(1, math.min(self.selectedCompetitorIndex, competitorCount))
  self.selectedCompetitorIndex = index
  local competitor = self.competitors[index]
  local defaultSlider = self.ui.default_slider_value or 0.5
  self.traitSkillPtr[0] = competitor.skill or defaultSlider
  self.traitConsistencyPtr[0] = competitor.consistency or defaultSlider
  self.traitRiskPtr[0] = competitor.risk or defaultSlider
end

function Panel:competitorDisplayName(competitor)
  if not competitor then
    return "?"
  end
  local name = competitor.name
  if name == nil or name == "" then
    return "?"
  end
  return tostring(name)
end

function Panel:loadFromDisk()
  local raw = model.loadRawConfig()
  local general, competitors, ui = model.configWithDefaults(raw)
  self:applyGeneralTable(general)
  self.competitors = cloneCompetitorListForEditing(competitors)
  self.ui = ui
  self.referenceTimePtr[0] = ui.default_player_time_sec or referenceTimeDefaultSec
  self.selectedCompetitorIndex = 1
  self:applySelectedCompetitorToTraitSliders()
end

function Panel:parseReferenceTimeSeconds()
  local value = self.referenceTimePtr[0]
  if type(value) ~= "number" or value ~= value then
    value = self.ui.default_player_time_sec or referenceTimeDefaultSec
    self.referenceTimePtr[0] = value
  end
  if value < referenceTimeMinSec then
    self.referenceTimePtr[0] = referenceTimeMinSec
    value = referenceTimeMinSec
  end
  return value
end

function Panel:buildVisualization()
  self:syncTraitsIntoSelectedCompetitor()
  local general = self:gatherGeneralTable()
  local referenceSec = self:parseReferenceTimeSeconds()
  local sliderMin = self.ui.slider_min or 0
  local sliderMax = self.ui.slider_max or 1
  return aiCompetitorsPreview.computeVisualization({
    general = general,
    referenceSec = referenceSec,
    skillUnit = model.sliderToUnit(self.traitSkillPtr[0], sliderMin, sliderMax),
    consistencyUnit = model.sliderToUnit(self.traitConsistencyPtr[0], sliderMin, sliderMax),
    riskUnit = model.sliderToUnit(self.traitRiskPtr[0], sliderMin, sliderMax),
  })
end

function Panel:drawGeneralParameterGroups()
  im.Spacing()
  pushSectionHeading(aiCompetitorsTexts.globalSection.title)
  pushMutedCaption(aiCompetitorsTexts.globalSection.subtitle)
  im.Separator()
  for groupIndex, group in ipairs(model.generalParamGroups) do
    if groupIndex > 1 then
      im.Spacing()
      im.Separator()
      im.Spacing()
    end
    local presentation = aiCompetitorsTexts.generalGroupPresentation[groupIndex]
    pushSectionHeading(presentation and presentation.title or group.title)
    im.TextWrapped(presentation and presentation.blurb or group.blurb)
    for _, fieldName in ipairs(group.fields) do
      local bounds = model.generalSliderBounds[fieldName]
      local ptr = self.generalFloatPtrs[fieldName]
      if bounds and ptr then
        im.PushID1(fieldName)
        local label = aiCompetitorsTexts.generalParamLabels[fieldName] or model.fieldLabel(fieldName)
        local tooltip = aiCompetitorsTexts.generalParamTooltips[fieldName]
        im.Text(label)
        im.SameLine()
        im.SetNextItemWidth(math.max(80, im.GetContentRegionAvailWidth() - 88))
        im.SliderFloat("##g", ptr, bounds.lo, bounds.hi, "")
        if tooltip and tooltip ~= "" then
          im.tooltip(tooltip)
        end
        im.SameLine()
        im.Text(model.formatParamValue(ptr[0]))
        im.PopID()
      end
    end
  end
end

function Panel:drawTraitSliders()
  im.Spacing()
  pushSectionHeading(aiCompetitorsTexts.driverPreviewSection.title)
  pushMutedCaption(aiCompetitorsTexts.driverPreviewSection.subtitle)
  im.Separator()
  local competitorCount = #self.competitors
  if competitorCount == 0 then
    im.Text(aiCompetitorsTexts.driverPreviewSection.emptycompetitors)
    return
  end

  local navigationTooltip = aiCompetitorsTexts.competitorNavigationTooltip
  im.BeginGroup()
  im.BeginDisabled(competitorCount <= 1)
  if im.Button("Prev##drv") then
    self:syncTraitsIntoSelectedCompetitor()
    self.selectedCompetitorIndex = math.max(1, self.selectedCompetitorIndex - 1)
    self:applySelectedCompetitorToTraitSliders()
  end
  im.EndDisabled()
  im.SameLine()
  im.BeginDisabled(competitorCount <= 1)
  if im.Button("Next##drv") then
    self:syncTraitsIntoSelectedCompetitor()
    self.selectedCompetitorIndex = math.min(competitorCount, self.selectedCompetitorIndex + 1)
    self:applySelectedCompetitorToTraitSliders()
  end
  im.EndDisabled()
  im.SameLine()
  im.Text(string.format(
    "%d / %d - %s",
    self.selectedCompetitorIndex,
    competitorCount,
    self:competitorDisplayName(self.competitors[self.selectedCompetitorIndex])
  ))
  im.EndGroup()
  im.tooltip(navigationTooltip)

  local sliderMin = self.ui.slider_min or 0
  local sliderMax = self.ui.slider_max or 1

  local function traitSliderRow(labelText, valuePtr, tooltipText)
    im.Text(labelText)
    im.PushItemWidth(-1)
    im.SliderFloat("##" .. labelText, valuePtr, sliderMin, sliderMax, "%.3f")
    if tooltipText and tooltipText ~= "" then
      im.tooltip(tooltipText)
    end
    im.PopItemWidth()
  end

  local tips = aiCompetitorsTexts.driverTraitTooltips
  traitSliderRow("Pace", self.traitSkillPtr, tips.Pace)
  traitSliderRow("Consistency", self.traitConsistencyPtr, tips.Consistency)
  traitSliderRow("Risk", self.traitRiskPtr, tips.Risk)
end

function Panel:drawReferenceAndDriversColumn()
  im.Spacing()
  pushSectionHeading(aiCompetitorsTexts.referenceSection.title)
  pushMutedCaption(aiCompetitorsTexts.referenceSection.subtitle)
  im.Separator()
  im.Text(aiCompetitorsTexts.referenceSection.referenceTimeLabel)
  local refHelp = aiCompetitorsTexts.playerReferenceHelp
  im.PushItemWidth(-1)
  im.InputFloat("##playerRef", self.referenceTimePtr, 1.0, 10.0, "%.3f")
  if refHelp and refHelp ~= "" then
    im.tooltip(refHelp)
  end
  im.PopItemWidth()
  im.Spacing()
  self:drawTraitSliders()
end

function Panel:trySaveToDisk()
  self:syncTraitsIntoSelectedCompetitor()
  local general = self:gatherGeneralTable()
  local referenceValue = self.referenceTimePtr[0]
  if type(referenceValue) == "number" and referenceValue == referenceValue then
    self.ui.default_player_time_sec = math.max(referenceTimeMinSec, referenceValue)
  else
    self.ui.default_player_time_sec = referenceTimeDefaultSec
  end
  local ok = model.saveConfig(general, self.competitors, self.ui)
  if ok then
    log("I", logTag, "Wrote " .. model.configPath)
  else
    log("E", logTag, "Failed to save " .. model.configPath)
  end
end

function Panel:draw(_mouseInfo, _dtReal, _dtSim, _dtRaw)
  local toolbar = aiCompetitorsTexts.toolbar
  im.HeaderText(toolbar.header)
  im.Separator()
  im.Text(toolbar.configPathPrefix .. model.configPath)
  im.SameLine()
  if im.Button(toolbar.reload) then
    self:loadFromDisk()
  end
  im.SameLine()
  if im.Button(toolbar.save) then
    self:trySaveToDisk()
  end

  im.Separator()

  local visualization = self:buildVisualization()

  local previewStrings = aiCompetitorsTexts.previewSection
  pushSectionHeading(previewStrings.title)
  pushMutedCaption(previewStrings.subtitle)
  im.Spacing()
  aiCompetitorsPlot.drawOutcomeShareRow(
    im,
    visualization,
    aiCompetitorsTexts.outcomeLabels,
    aiCompetitorsPlot.outcomeLineColors,
    model
  )
  im.Separator()

  local chartStrings = aiCompetitorsTexts.chart
  pushSectionHeading(chartStrings.title)
  pushMutedCaption(chartStrings.subtitle)
  im.TextColored(im.ImVec4(0.65, 0.65, 0.65, 1), chartStrings.legendHint)
  aiCompetitorsPlot.drawFinishTimeChart(im, visualization, chartStrings)

  im.Separator()

  local bottomWidth = im.GetContentRegionAvailWidth()
  local leftColumnWidth = math.max(260, bottomWidth * 0.5 - 6)
  im.BeginChild1("##aiCompetitorsGeneral", im.ImVec2(leftColumnWidth, 0), true)
  self:drawGeneralParameterGroups()
  im.EndChild()
  im.SameLine()
  im.BeginChild1("##aiCompetitorscompetitors", im.ImVec2(0, 0), true)
  self:drawReferenceAndDriversColumn()
  im.EndChild()
end

return function()
  local instance = {}
  setmetatable(instance, Panel)
  instance:init()
  return instance
end
