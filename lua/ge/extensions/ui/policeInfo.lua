-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local liveData = {
  state = 0, -- 0 = idle, 1 = pursuit, 2 = final
  pursuitLevel = 0,
  sightValue = 0,
  duration = 0,
  arrest = 0,
  evade = 0,
  durationStr = '',
  flags = {
    pursuitActive = false,
    sightActive = false,
    arrestActive = false,
    arrestComplete = false,
    evadeActive = false,
    evadeComplete = false
  }
}

M.targetId = nil -- if set, uses this vehicle's pursuit data instead of the player's
M.showFinalStats = true -- set to false to disable stats overview after a pursuit
M.enabled = true -- set to false to disable automatic updates

local function formatTime(seconds) -- TODO: have and use a common function instead
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor(seconds % 3600 / 60)
  local seconds = seconds % 60
  if hours > 0 then
    return string.format("%2d:%02d:%02d", hours, minutes, seconds)
  else
    return string.format("%2d:%02d", minutes, seconds)
  end
end

local function isPursuit() -- returns true if a pursuit is or was active
  return liveData.state > 0
end

local function resetPursuitTable() -- resets values to zero
  for k, v in pairs(liveData) do
    if type(v) == 'number' then
      liveData[k] = 0
    end
  end
  for k, v in pairs(liveData.flags) do
    liveData.flags[k] = false
  end
  liveData.durationStr = formatTime(0)
  guihooks.trigger('PoliceAlertClear')
  guihooks.queueStream('policePursuit', liveData)
end

local function onVehicleSwitched(_, id)
  if M.enabled and not M.targetId then
    resetPursuitTable()
  end
end

local function onPursuitOffense(vehId, name, data)
  if M.enabled then
    local alert = {
      icon = 'listSmall',
      text = {txt = 'ui.apps.police.offenseAlert', context = {value = _tr('ui.traffic.infractions.'..name, name)}},
      duration = 3
    }
    guihooks.trigger('PoliceAlertPush', alert)
  end
end

local function onPursuitAction(vehId, action, data)
  if M.enabled then
    if vehId == M.targetId or vehId == be:getPlayerVehicleID(0) then
      local pursuit = gameplay_police.getPursuitData(M.targetId)
      if pursuit and (action == 'arrest' or action == 'evade') then
        if action == 'arrest' then
          liveData.arrest = 1
          liveData.flags.arrestComplete = true
        end
        if action == 'evade' then
          liveData.evade = 1
          liveData.flags.evadeComplete = true
        end
        liveData.state = 2

        guihooks.trigger('PoliceAlertClear') -- call this first to clear any existing alerts
        guihooks.queueStream('policePursuit', liveData)

        local alerts = {}
        if M.showFinalStats then
          table.insert(alerts, {
            icon = 'listSmall',
            text = {txt = 'ui.apps.police.score', context = {value = math.floor(pursuit.score)}},
            duration = 3
          })
          table.insert(alerts, {
            icon = 'listSmall',
            text = {txt = 'ui.apps.police.offensesCount', context = {value = pursuit.offensesCount}},
            duration = 3
          })
          if pursuit.roadblocks > 0 then
            table.insert(alerts, {
              icon = 'listSmall',
              text = {txt = 'ui.apps.police.roadblocks', context = {value = pursuit.roadblocks}},
              duration = 3
            })
          else
            table.insert(alerts, {
              icon = 'listSmall',
              text = {txt = 'ui.apps.police.policeCount', context = {value = pursuit.policeCount}},
              duration = 3
            })
          end
        else
          if action == 'arrest' then
            table.insert(alerts, {
              icon = 'abandon',
              text = 'ui.scenarios.end.result.fail',
              duration = 5
            })
          elseif action == 'evade' then
            table.insert(alerts, {
              icon = 'checkmarkBold',
              text = 'ui.scenarios.end.result.success',
              duration = 5
            })
          end
        end

        for _, alert in ipairs(alerts) do
          guihooks.trigger('PoliceAlertPush', alert)
        end
      end
    end
  end
end

local function onPursuitStatsEnded()
  if liveData.state == 2 then
    resetPursuitTable()
  end
end

local function onUiChangedState()
  resetPursuitTable()
end

local function onGuiUpdate(dt)
  if not be:getEnabled() or not M.enabled then return end

  local pd = liveData
  local pursuit = gameplay_police.getPursuitData(M.targetId) -- vehicle pursuit data, uses player by default

  if pd.state == 2 then
    if pursuit and pursuit.mode > 0 then
      resetPursuitTable()
    else
      return
    end
  end

  if not pursuit then
    resetPursuitTable()
    return
  end

  pd.pursuitLevel = pursuit.mode
  pd.sightValue = pursuit.sightValue
  pd.arrest = pursuit.timers.arrestValue > 0 and pursuit.timers.arrestValue or lerp(pd.arrest, pursuit.timers.arrestValue, 0.5)
  pd.evade = pursuit.timers.evadeValue > 0 and pursuit.timers.evadeValue or lerp(pd.evade, pursuit.timers.evadeValue, 0.5)
  -- lerp is used to make the progress bar transition smoothly when values get reset to zero

  pd.duration = pursuit.timers.main
  pd.durationStr = formatTime(pd.duration)

  pd.flags.pursuitActive = pd.duration > 0
  pd.flags.sightActive = pd.sightValue >= 0.5
  pd.flags.arrestActive = pd.arrest > 0.001
  pd.flags.arrestComplete = pd.arrest >= 1
  pd.flags.evadeActive = pd.evade > 0.001
  pd.flags.evadeComplete = pd.evade >= 1

  guihooks.queueStream('policePursuit', pd)
end

M.isPursuit = isPursuit
M.resetPursuitTable = resetPursuitTable

M.onVehicleSwitched = onVehicleSwitched
M.onPursuitOffense = onPursuitOffense
M.onPursuitAction = onPursuitAction
M.onPursuitStatsEnded = onPursuitStatsEnded
M.onUiChangedState = onUiChangedState
M.onGuiUpdate = onGuiUpdate

return M