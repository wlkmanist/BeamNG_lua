-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local RecoveryClockAdvance = require('/lua/ge/extensions/gameplay/rally/recoveryClockAdvance')
local Penalties = require('/lua/ge/extensions/gameplay/rally/loop/penalties')

local C = {}
local logTag = 'rallyStageInfoPanel'

C.name = 'Rally Info Panel'
C.description = 'Builds the consolidated rally start-screen panel: stats outline (distance + surface), the per-mission description blurb, and the general rally text with live recovery/flip rules.'
C.color = RallyUtil.rally_flowgraph_color
C.icon = ui_flowgraph_editor.nodeIcons.ui
C.tags = { 'rally', 'ui', 'start', 'screen' }
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = '', chainFlow = true },
  { dir = 'in', type = 'bool', name = 'isLoop', description = 'If true, includes road-section rules (loop). If false, special-stage only (stage).' },
  { dir = 'out', type = 'flow', name = 'flow', description = '', chainFlow = true },
}

-- Read the authored stats. Prefer the loaded driveline (drivelineV3.stats); fall back to
-- reading the spline file directly so the panel works regardless of driveline load timing.
function C:readStats()
  local rm = gameplay_rally and gameplay_rally.getRallyManager and gameplay_rally.getRallyManager()
  if rm and rm.drivelineV3 and rm.drivelineV3.stats then
    return rm.drivelineV3.stats
  end
  local missionDir = (rm and rm.missionDir) or (self.mgr.activity and self.mgr.activity.missionFolder)
  if missionDir then
    local data = jsonReadFile(RallyUtil.drivelineSplineFile(missionDir))
    if data then return data.stats end
  end
  return nil
end

-- Read the stats for a specific mission folder's driveline spline.
function C:readStatsForFolder(folder)
  if not folder then return nil end
  local data = jsonReadFile(RallyUtil.drivelineSplineFile(folder))
  if data then return data.stats end
  return nil
end

-- Shape a raw stats table into UI-ready distance + sorted surface percentages.
function C:formatStats(stats)
  if not stats then return nil end

  local out = {}
  if stats.raceDistanceKms then
    -- unit-inclusive string so a future switch to miles is a one-place change
    out.distance = string.format("%.2f km", stats.raceDistanceKms)
  end

  if stats.surfacePercentages then
    local surfaces = {}
    for name, pct in pairs(stats.surfacePercentages) do
      local rounded = math.floor((tonumber(pct) or 0) + 0.5)
      if rounded > 0 then
        table.insert(surfaces, { label = "missions.missions.rally.surface." .. tostring(name), value = rounded })
      end
    end
    table.sort(surfaces, function(a, b) return a.value > b.value end)
    if #surfaces > 0 then out.surfaces = surfaces end
  end

  if not out.distance and not out.surfaces then return nil end
  return out
end

function C:buildStats()
  return self:formatStats(self:readStats())
end

function C:buildLoopStats()
  local lm = gameplay_rallyLoop and gameplay_rallyLoop.getManager and gameplay_rallyLoop.getManager()
  if not lm or (lm.isScheduleValid and not lm:isScheduleValid()) then return nil end

  local ssDistance = lm.getTotalSSDistanceKm and lm:getTotalSSDistanceKm()
  local liaisonDistance = lm.getTotalRoadSectionDistanceKm and lm:getTotalRoadSectionDistanceKm()
  local totalDistance = lm.getTotalDistanceKm and lm:getTotalDistanceKm()
  if ssDistance == nil or liaisonDistance == nil or totalDistance == nil then return nil end

  return {
    specialStageDistance = string.format("%.2f km", ssDistance),
    liaisonDistance = string.format("%.2f km", liaisonDistance),
    totalDistance = string.format("%.2f km", totalDistance),
  }
end

-- For loops: one entry per filled special stage, in run order, with the stage's
-- title + its own distance/surfaces (read from that stage's driveline spline).
function C:buildLoopStages()
  local activity = self.mgr.activity
  local mtd = activity and activity.missionTypeData
  if not mtd then return nil end

  local stages = {}
  for i = 1, 4 do
    local value = mtd["stage"..i.."_rallyStage"]
    if value ~= nil and value ~= "<none>" and value ~= "" then
      local stageId = value:match("%((.+)%)$")
      local stageMission = stageId and gameplay_missions_missions.getMissionById(stageId)
      if stageMission then
        local entry = { label = stageMission.name }
        local fmt = self:formatStats(self:readStatsForFolder(stageMission.missionFolder))
        if fmt then
          entry.distance = fmt.distance
          entry.surfaces = fmt.surfaces
        end
        table.insert(stages, entry)
      end
    end
  end

  if #stages == 0 then return nil end
  return stages
end

function C:getServiceParkSpeedLimit()
  local lm = gameplay_rallyLoop and gameplay_rallyLoop.getManager and gameplay_rallyLoop.getManager()
  if lm and lm.getServiceParkSpeedLimitDisplay then
    return lm:getServiceParkSpeedLimitDisplay()
  end
  local kph = (lm and lm.getServiceParkSpeedLimitKph and lm:getServiceParkSpeedLimitKph()) or 30
  return string.format("%d km/h", kph)
end

function C:buildRules(repairEnabled)
  -- Special-stage recovery is a flat penalty parameterized from the live value.
  local ssRecovery = RecoveryClockAdvance.specialStageSeconds.recovery

  if self.pinIn.isLoop.value then
    -- On loops, flips are free on special stages but still cost time on liaisons,
    -- so the liaison flip value is parameterized from the live penalty.
    local loopFlipRule = { txt = "missions.missions.rally.startScreen.rules.loop.flip", context = { flip = RecoveryClockAdvance.nonSpecialStageSeconds.flip } }
    local result = {
      {
        txt = repairEnabled
          and "missions.missions.rally.startScreen.rules.loop.recoveryStage.repairOn"
          or "missions.missions.rally.startScreen.rules.loop.recoveryStage.repairOff",
        context = { recovery = ssRecovery }
      },
      "missions.missions.rally.startScreen.rules.loop.recoveryLiaison",
      loopFlipRule,
      { txt = "missions.missions.rally.startScreen.rules.loop.servicePark", context = { speedLimit = self:getServiceParkSpeedLimit() } },
      "missions.missions.rally.startScreen.rules.loop.liaisonSpeed",
    }
    return result
  end

  local result = {
    {
      txt = repairEnabled
        and "missions.missions.rally.startScreen.rules.recovery.repairOn"
        or "missions.missions.rally.startScreen.rules.recovery.repairOff",
      context = { recovery = ssRecovery }
    },
    "missions.missions.rally.startScreen.rules.flip",
    "missions.missions.rally.startScreen.rules.stopControl",
  }
  return result
end

function C:work()
  self.pinOut.flow.value = self.pinIn.flow.value
  self.mgr.modules.ui:setPageIcon('main', 'roadInfo')

  local blurb = self.mgr.activity and self.mgr.activity.description
  if blurb == "" then blurb = nil end

  -- Single stages show one distance/surface outline; loops show aggregate
  -- distances plus each member stage's own distance/surfaces.
  local stats, stages
  local header
  if self.pinIn.isLoop.value then
    header = "missions.missions.rally.startScreen.loopInfoHeader"
    stats = self:buildLoopStats()
    stages = self:buildLoopStages()
  else
    header = "missions.missions.rally.startScreen.stageInfoHeader"
    stats = self:buildStats()
  end

  local repairEnabled = true
  local activity = self.mgr.activity
  if activity and activity.lastUserSettings and activity.lastUserSettings.rallyRepairVehicleOnRecovery ~= nil then
    repairEnabled = activity.lastUserSettings.rallyRepairVehicleOnRecovery == true
  elseif settings and settings.getValue then
    local remembered = settings.getValue('rallyRepairVehicleOnRecovery')
    if remembered ~= nil then repairEnabled = remembered == true end
  end

  self.mgr.modules.ui:addUIElement({
    type = 'rallyStageInfo',
    header = header,
    stats = stats,
    stages = stages,
    blurb = blurb,
    rules = self:buildRules(repairEnabled),
    rulesRepairOn = self:buildRules(true),
    rulesRepairOff = self:buildRules(false),
    ngrcRule = "missions.missions.rally.startScreen.rules.ngrcBadge",
    falseStartsRuleOn = self.pinIn.isLoop.value and {
      txt = "missions.missions.rally.startScreen.rules.loop.falseStarts.on",
      context = { seconds = Penalties.falseStartPenaltySeconds }
    } or nil,
    falseStartsRuleOff = self.pinIn.isLoop.value
      and "missions.missions.rally.startScreen.rules.loop.falseStarts.off"
      or nil,
    earlyPenaltiesRuleOn = self.pinIn.isLoop.value and {
      txt = "missions.missions.rally.startScreen.rules.loop.earlyPenalties.on",
      context = { seconds = Penalties.timeControlPenaltySecondsPerMinute }
    } or nil,
    earlyPenaltiesRuleOff = self.pinIn.isLoop.value
      and "missions.missions.rally.startScreen.rules.loop.earlyPenalties.off"
      or nil,
    pages = { main = true },
  })
end

return _flowgraph_createNode(C)
