-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local voicepack = require('/lua/ge/extensions/gameplay/rally/voicepack')

local C = {}

local logTag = 'startScreenRallySettings'

C.name = 'StartScreen Rally Settings'
C.color = ui_flowgraph_editor.nodeColors.ui
C.description = 'Rally start-screen settings: codriver and mission behavior toggles.'
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = '', chainFlow = true },
  { dir = 'out', type = 'flow', name = 'flow', description = '', chainFlow = true },
}

C.tags = { 'start', 'screen', 'intro', 'ui', 'rally', 'settings' }

local settingKeys = {
  rallyRepairVehicleOnRecovery = true,
  rallyEnableFalseStarts = true,
  rallyEnableEarlyTimeControlPenalties = true,
}

local function getLoopManager()
  if extensions.isExtensionLoaded('gameplay_rallyLoop') and gameplay_rallyLoop then
    return gameplay_rallyLoop.getManager()
  end
  return nil
end

function C:init()
  self.panel = {
    type = 'coDriverSelector',
    header = 'missions.missions.rally.startScreen.settingsHeader',
    options = {},
    selectedValue = '',
    settings = {},
    pages = { main = true },
  }
  self.pendingValue = nil
  self.pendingSettings = {}
end

function C:_executionStarted()
  self.pendingValue = nil
  self.pendingSettings = {}
end

function C:getMission(loopManager)
  if loopManager then return loopManager:getRallyLoopMission() end
  return self.mgr.activity
end

function C:buildLoopOptions(loopManager)
  local loopMission = loopManager:getRallyLoopMission()
  if not (loopMission and loopMission.missionTypeData) then return nil end

  local currentValue = loopMission.lastUserSettings and loopMission.lastUserSettings.rallyVoicepackPick or ''
  local setting = voicepack.buildLoopMissionUserSetting(loopMission.missionTypeData, currentValue)
  if not setting then return nil end

  local options = {}
  for _, o in ipairs(setting.values or {}) do
    table.insert(options, { label = o.l, value = o.v, shortLabel = o.shortLabel, detail = o.detail })
  end
  return options, setting.value
end

function C:buildStageOptions(rm)
  local missionDir = rm:getMissionDir()
  local missionId = rm:getMissionId()
  local currentValue = voicepack.settingValueForPick(rm:getVoicepackPick())
  local setting = voicepack.buildMissionUserSetting(missionDir, missionId, currentValue)
  if not setting then return nil end

  local options = {}
  for _, o in ipairs(setting.values or {}) do
    table.insert(options, { label = o.l, value = o.v, shortLabel = o.shortLabel, detail = o.detail })
  end
  return options, setting.value
end

function C:buildBoolSettings(mission)
  if not (mission and mission.getUserSettingsData) then return {} end

  local result = {}
  for _, setting in ipairs(mission:getUserSettingsData() or {}) do
    if setting.type == 'bool' and settingKeys[setting.key] then
      local value = self.pendingSettings[setting.key]
      if value == nil then value = setting.value == true end
      table.insert(result, {
        key = setting.key,
        label = setting.label,
        type = setting.type,
        value = value,
      })
    end
  end
  return result
end

function C:work()
  self.pinOut.flow.value = self.pinIn.flow.value

  local options, selectedValue
  local loopManager = getLoopManager()
  local mission = self:getMission(loopManager)
  if loopManager then
    options, selectedValue = self:buildLoopOptions(loopManager)
  else
    local rm = gameplay_rally and gameplay_rally.getRallyManager()
    if not rm then
      log('W', logTag, 'no rally manager available; skipping settings panel')
      return
    end
    options, selectedValue = self:buildStageOptions(rm)
  end

  if not options or #options == 0 then
    log('W', logTag, 'no codriver options available; skipping settings panel')
    return
  end

  self.panel.options = options
  self.panel.selectedValue = self.pendingValue or selectedValue or ''
  self.panel.settings = self:buildBoolSettings(mission)
  self.panel.note = loopManager and 'missions.missions.rally.startScreen.settings.loopTimeNote' or nil
  self.mgr.modules.ui:addUIElement(self.panel)
end

function C:onCoDriverSelectedByPanel(value)
  self.pendingValue = value
  self.panel.selectedValue = value
end

-- Update the mission's session-local settings immediately so the loop manager can
-- reliably re-read them in its own Start hook regardless of extension hook order.
-- Cloud persistence remains deferred until Start is committed.
function C:onRallyStartSettingChanged(key, value)
  if type(key) == 'table' then
    local payload = key
    key = payload.key
    value = payload.value
  end
  if not settingKeys[key] then return end
  value = value == true
  self.pendingSettings[key] = value

  local mission = self:getMission(getLoopManager())
  if mission then
    mission.lastUserSettings = mission.lastUserSettings or {}
    mission.lastUserSettings[key] = value
  end

  for _, setting in ipairs(self.panel.settings or {}) do
    if setting.key == key then
      setting.value = value
      break
    end
  end
end

function C:onUIStartButtonClicked()
  for key, value in pairs(self.pendingSettings) do
    if settings and settings.setValue then settings.setValue(key, value) end
  end
  self.pendingSettings = {}

  if self.pendingValue ~= nil then
    self:applyPick(self.pendingValue)
    self.pendingValue = nil
  end
end

function C:applyPick(value)
  local rm = gameplay_rally and gameplay_rally.getRallyManager()
  local loopManager = getLoopManager()

  if loopManager then
    local loopMission = loopManager:getRallyLoopMission()
    if loopMission then
      loopMission.lastUserSettings = loopMission.lastUserSettings or {}
      loopMission.lastUserSettings.rallyVoicepackPick = value
      voicepack.addLoopMissionSettingToMRU(loopMission.missionTypeData, value)
    end
    if rm then
      local pick = voicepack.resolveLoopVoicepackPick(rm:getMissionDir(), rm:getMissionId(), value)
        or voicepack.pickFromSettingValue(value)
      if not rm:reloadVoicepackAssets(pick, { writeSettings = false }) then
        log('E', logTag, 'failed to reload rally assets after codriver selection')
      end
    end
  else
    if not rm then
      log('W', logTag, 'no rally manager available; ignoring codriver selection')
      return
    end
    local pick = voicepack.pickFromSettingValue(value)
    if not rm:reloadVoicepackAssets(pick, { writeSettings = true }) then
      log('E', logTag, 'failed to reload rally assets after codriver selection')
    end
  end
end

return _flowgraph_createNode(C)
