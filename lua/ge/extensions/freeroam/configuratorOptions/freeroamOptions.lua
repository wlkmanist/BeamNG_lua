local M = {}
local defaultEnvironmentDateParts = {year = 2026, month = 6, day = 20}

local function getDefaultEnvironmentDate(level)
  local defaultDate = level and level.defaultDate or {}
  return os.time({
    year = tonumber(defaultDate.year) or defaultEnvironmentDateParts.year,
    month = tonumber(defaultDate.month) or defaultEnvironmentDateParts.month,
    day = tonumber(defaultDate.day) or defaultEnvironmentDateParts.day,
    hour = 12
  })
end

local function onFreeroamConfiguratorGetOptions(level, options)
  -- Traffic options
  if level.supportsTraffic then
    local trafficGroup = {
      order = 100,
      options = {
        {
          label = _tr("ui.apps.traffic.name"),
          icon = "trafficLight",
          value = "enabled", -- Default value, will be overridden by current configuration
          key = "traffic_trafficMode",
          type = "select",
          options = {
            { label = _tr("ui.common.disabled"), value = "disabled" },
            { label = _tr("ui.apps.traffic.parkedOnly"), value = "parkedOnly", style="active" },
            { label = _tr("ui.apps.traffic.normal"), value = "enabled", style="active" },
            { label = _tr("ui.apps.traffic.police"), value = "police", style="active" },
          },
        }
      }
    }
    table.insert(options, trafficGroup)
  else
    table.insert(options, {
      order = 100,
      options = {
        {
          label = _tr("ui.apps.traffic.notSupported"),
          icon = "trafficLight",
          disabled = true,
        }
      }
    })
  end

  -- Time of day options
  local timeOfDayOptions = core_levels.getTimeOfDayOptions(level.levelName)
  if timeOfDayOptions and #timeOfDayOptions > 0 then
    local defaultEnvironmentDate = getDefaultEnvironmentDate(level)
    local timeOfDayGroup = {
      order = 200,
      options = {}
    }

    -- Time option
    local timeOption = {
      label = _tr("ui.environment.timeOfDay"),
      value = "default", -- Default value, will be overridden by current configuration
      key = "environment_timeOfDay",
      icon = "weather",
      type = "select",
      options = {
        { label = _tr("ui.common.default"), value = "default" },
        { label = _tr("ui.environment.now"), value = "current", style = "active" },
        { label = _tr("ui.environment.nowUtc"), value = "currentUtc", style = "active" },
      },
    }

    for _, option in ipairs(timeOfDayOptions) do
      table.insert(timeOption.options, { label = _tr(option.label), value = option.key, style = "active" })
    end

    table.insert(timeOfDayGroup.options, timeOption)

    table.insert(timeOfDayGroup.options, {
      label = _tr("ui.environment.date"),
      value = defaultEnvironmentDate,
      resetValue = defaultEnvironmentDate,
      resetLabel = _tr("ui.common.reset"),
      todayLabel = _tr("ui.environment.today"),
      key = "environment_date",
      icon = "weather",
      type = "date",
    })

    -- Play option
    local playOption = {
      label = _tr("ui.environment.timeOfDayPlay"),
      value = "disabled", -- Default value, will be overridden by current configuration
      key = "environment_timePlay",
      icon = "weather",
      type = "select",
      options = {
        { label = _tr("ui.common.disabled"), value = "disabled" },
        { label = _tr("ui.environment.realtime") .. " (24h)", value = "realtime", style="active" },
        { label = _tr("editor.camera.speedSlow") .. " (2h)", value = "slow", style="active" },
        { label = _tr("editor.camera.speedNormal") .. " (30m)", value = "normal", style="active" },
        { label = _tr("editor.camera.speedFast") .. " (5m)", value = "fast", style="active" },
      },
    }

    table.insert(timeOfDayGroup.options, playOption)
    table.insert(options, timeOfDayGroup)
  else
    table.insert(options, {
      order = 200,
      options = {
        {
          label = _tr("ui.environment.timeOfDay.notSupported"),
          icon = "weather",
          disabled = true,
        }
      }
    })
  end
end



-- Change traffic spawning option
local function changeTrafficSpawningOption(trafficMode)
  freeroam_freeroam.spawningOptionsHelper.trafficMode = trafficMode

  -- Set all traffic-related values based on mode
  if trafficMode == "disabled" then
    freeroam_freeroam.spawningOptionsHelper.trafficMode = "disabled"
    freeroam_freeroam.spawningOptionsHelper.trafficPolice = "disabled"
    freeroam_freeroam.spawningOptionsHelper.trafficParked = "disabled"
  elseif trafficMode == "parkedOnly" then
    freeroam_freeroam.spawningOptionsHelper.trafficMode = "disabled" -- No moving traffic
    freeroam_freeroam.spawningOptionsHelper.trafficPolice = "disabled"
    freeroam_freeroam.spawningOptionsHelper.trafficParked = "enabled" -- Only parked vehicles
  elseif trafficMode == "enabled" then
    freeroam_freeroam.spawningOptionsHelper.trafficMode = "enabled"
    freeroam_freeroam.spawningOptionsHelper.trafficPolice = "disabled"
    freeroam_freeroam.spawningOptionsHelper.trafficParked = "enabled" -- Regular traffic + parked
  elseif trafficMode == "police" then
    freeroam_freeroam.spawningOptionsHelper.trafficMode = "enabled" -- Regular traffic enabled
    freeroam_freeroam.spawningOptionsHelper.trafficPolice = "enabled"
    freeroam_freeroam.spawningOptionsHelper.trafficParked = "enabled" -- Police traffic + parked
  end
end

-- Handle option updates for freeroam-specific options
local function onFreeroamConfiguratorApplyOptions(options)
  -- Apply the option to the freeroam spawning options helper
  if options.traffic_trafficMode then
    changeTrafficSpawningOption(options.traffic_trafficMode)
  end
  if options.environment_timeOfDay then
    freeroam_freeroam.spawningOptionsHelper.timeOfDay = options.environment_timeOfDay
  end
  if options.environment_date then
    freeroam_freeroam.spawningOptionsHelper.date = options.environment_date
  end
  if options.environment_timePlay then
    freeroam_freeroam.spawningOptionsHelper.timePlay = options.environment_timePlay
  end
end

M.onFreeroamConfiguratorGetOptions = onFreeroamConfiguratorGetOptions
M.onFreeroamConfiguratorApplyOptions = onFreeroamConfiguratorApplyOptions
M.getDefaultEnvironmentDate = function(levelName)
  return getDefaultEnvironmentDate(core_levels.getLevelByName(levelName))
end

return M
