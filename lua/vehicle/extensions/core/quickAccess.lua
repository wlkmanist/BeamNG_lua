-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- this is a proxy for the GE module quickaccess

local M = {}

local constants = {
  mphToMs = 1 / 2.237,
  kmhToMs = 1 / 3.6
}
local menuTree = {}
local currentMenuItems = {}

-- same as GE/core/quickAccess/addEntry - sync with it!
local function addEntry(_args)
  local args = deepcopy(_args) -- do not modify the outside table by any chance
  if type(args.generator) ~= "function" and (type(args.title) ~= "string" or (type(args.onSelect) ~= "function" and type(args["goto"]) ~= "string")) then
    -- TODO: add proper warning/error
    log("W", "quickaccess", "Menu item needs at least a title and an onSelect function callback: " .. dumps(args))
  --return false
  end
  -- defaults
  if args.level == nil then
    args.level = "/"
  end

  if type(args.level) ~= "string" then
    log("E", "quickaccess", "Menu item level incorrect, needs to be a string: " .. dumps(args))
    return false
  end
  if string.sub(args.level, string.len(args.level)) ~= "/" then
    args.level = args.level .. "/"
  end -- make sure there is always a trailing slash in the level

  if menuTree[args.level] == nil then
    -- add new level if not existing
    menuTree[args.level] = {}
  end

  if args.uniqueID then
    -- make this entry unique in this level
    local replaced = false
    for k, v in pairs(menuTree[args.level]) do
      if v.uniqueID == args.uniqueID then
        menuTree[args.level][k] = args
        replaced = true
        break
      end
    end
    if not replaced then
      table.insert(menuTree[args.level], args)
    end
  else
    -- always insert
    table.insert(menuTree[args.level], args)
  end

  return true
end

local function onExtensionLoaded()
  if quickAccess then
    -- do not register twice
    log("E", "quickAccess", "Error: module cannot be loaded twice: " .. debug.traceback())
    return
  end

  addEntry({level = "/", title = "ui.radialmenu2.electrics", ["goto"] = "/electrics/", icon = "radial_electrics"})

  --addEntry({ level = '/', title = 'test', onSelect = function() print('test') end} )

  -- headlights
  addEntry(
    {
      level = "/electrics/",
      generator = function(entries)
        local e = {title = "ui.radialmenu2.electrics.headlights", ["goto"] = "/electrics/headlights/", icon = "radial_headlights"}
        if electrics.values.lights_state == 1 then
          e.color = "#33ff33"
          e.icon = "radial_headlights_low"
        end
        if electrics.values.lights_state == 2 then
          e.color = "#3333ff"
        end
        table.insert(entries, e)
      end
    }
  )

  addEntry(
    {
      level = "/electrics/headlights/",
      generator = function(entries)
        local e = {title = "ui.radialmenu2.electrics.headlights.off", icon = "radial_headlights_off", onSelect = function()
            electrics.setLightsState(0)
            return {"reload"}
          end}
        if electrics.values.lights_state == 0 then
          e.color = "#ff6600"
        end
        table.insert(entries, e)

        e = {title = "ui.radialmenu2.electrics.headlights.low", icon = "radial_headlights_low", onSelect = function()
            electrics.setLightsState(1)
            return {"reload"}
          end}
        if electrics.values.lights_state == 1 then
          e.color = "#33ff33"
        end
        table.insert(entries, e)

        e = {title = "ui.radialmenu2.electrics.headlights.high", icon = "radial_headlights", onSelect = function()
            electrics.setLightsState(2)
            return {"reload"}
          end}
        if electrics.values.lights_state == 2 then
          e.color = "#3333ff"
        end
        table.insert(entries, e)
      end
    }
  )

  addEntry(
    {
      level = "/electrics/",
      generator = function(entries)
        -- warning lights
        local e = {title = "ui.radialmenu2.electrics.hazard_lights", icon = "radial_hazard_lights", onSelect = function()
            electrics.toggle_warn_signal()
            return {"reload"}
          end}
        if electrics.values.hazard_enabled == 1 then
          e.color = "#ff0000"
        end
        table.insert(entries, e)

        -- fog lights
        e = {title = "ui.radialmenu2.electrics.fog_lights", icon = "radial_fog_lights", onSelect = function()
            electrics.toggle_fog_lights()
            return {"reload"}
          end}
        if electrics.values.fog == 1 then
          e.color = "#ff6600"
        end
        table.insert(entries, e)

        -- lightbar
        e = {title = "ui.radialmenu2.electrics.lightbar", icon = "radial_lightbar", onSelect = function()
            electrics.toggle_lightbar_signal()
            return {"reload"}
          end}
        if electrics.values.lightbar == 1 then
          e.color = "#ff6600"
        end
        if electrics.values.lightbar == 2 then
          e.color = "#ff0000"
        end
        table.insert(entries, e)

        -- signals
        e = {title = "ui.radialmenu2.electrics.signals", icon = "radial_signal", ["goto"] = "/electrics/signals/"}
        if electrics.values.hazard_enabled == 0 and (electrics.values.signal_left_input == 1 or electrics.values.signal_right_input == 1) then
          e.color = "#33ff33"
        end
        table.insert(entries, e)
      end
    }
  )

  addEntry(
    {
      level = "/electrics/signals/",
      generator = function(entries)
        local e = {title = "ui.radialmenu2.electrics.signals.left", priority = 2, icon = "radial_left_arrow", onSelect = function()
            electrics.toggle_left_signal()
            return {"reload"}
          end}
        if electrics.values.hazard_enabled == 0 and electrics.values.signal_left_input == 1 then
          e.color = "#33ff33"
        end
        table.insert(entries, e)

        e = {title = "ui.radialmenu2.electrics.signals.right", priority = 1, icon = "radial_right_arrow", onSelect = function()
            electrics.toggle_right_signal()
            return {"reload"}
          end}
        if electrics.values.hazard_enabled == 0 and electrics.values.signal_right_input == 1 then
          e.color = "#33ff33"
        end
        table.insert(entries, e)
      end
    }
  )

  addEntry(
    {
      level = "/",
      generator = function(entries)
        if beamstate.hasCouplers() then
          table.insert(entries, {title = "ui.radialmenu2.couplers", priority = 30, ["goto"] = "/couplers/", icon = "radial_couplers"})
        end
      end
    }
  )

  addEntry(
    {
      level = "/couplers/",
      generator = function(entries)
        table.insert(
          entries,
          {title = "ui.radialmenu2.couplers.attach_all", icon = "radial_attach_all", onSelect = function()
              beamstate.attachCouplers()
              return {"reload"}
            end}
        )
        table.insert(
          entries,
          {title = "ui.radialmenu2.couplers.toggle", icon = "radial_toggle", onSelect = function()
              beamstate.toggleCouplers()
              return {"reload"}
            end}
        )
        table.insert(
          entries,
          {title = "ui.radialmenu2.couplers.detach_all", icon = "radial_detach_all", onSelect = function()
              beamstate.detachCouplers()
              return {"reload"}
            end}
        )
      end
    }
  )

  addEntry(
    {
      level = "/",
      generator = function(entries)
        if next(powertrain.getDevices()) then
          -- has a powertrain
          table.insert(entries, {title = "ui.radialmenu2.powertrain", priority = 40, ["goto"] = "/powertrain/", icon = "radial_powertrain"})
        end
      end
    }
  )

  addEntry(
    {
      level = "/powertrain/",
      generator = function(entries)
        local hasElectricMotor = #powertrain.getDevicesByType("electricMotor") > 0

        table.insert(
          entries,
          {title = "ui.radialmenu2.powertrain.gearbox_mode", icon = "radial_gearbox_mode", onSelect = function()
              controller.mainController.cycleGearboxModes()
              return {"reload"}
            end}
        )

        if hasElectricMotor and electrics.values.maxRegenStrength then
          -- TODO: icon
          table.insert(entries, {title = "ui.radialmenu2.powertrain.regen", ["goto"] = "/powertrain/regen/", icon = "powertrain_motor_electric"})
        end
      end
    }
  )

  addEntry(
    {
      level = "/powertrain/",
      generator = function(entries)
        local e = {
          title = "ui.radialmenu2.powertrain.engine",
          icon = "garage_engine",
          onSelect = function()
            if controller.mainController.engineInfo[18] == 1 then --running
              controller.mainController.setStarter(false)
              if controller.mainController.setEngineIgnition ~= nil then
                controller.mainController.setEngineIgnition(false)
              end
            else
              controller.mainController.setStarter(true)
            end
          end
        }
        if controller.mainController.engineInfo[18] == 1 then
          e.color = "#ff6600"
        end
        table.insert(entries, e)
      end
    }
  )

  -- regenerative braking
  -- TODO: Icons
  addEntry(
    {
      level = "/powertrain/regen/",
      generator = function(entries)
        local maxStrength = electrics.values.maxRegenStrength or 3

        for strength = 0, maxStrength do
          local title, icon, context
          local numItems = maxStrength + 1
          local priority = (strength + math.floor(numItems / 2)) % numItems * 10

          if strength == 0 then
            title = "ui.radialmenu2.powertrain.regen.off"
            icon = "material_not_interested"
          elseif strength == maxStrength then
            title = "ui.radialmenu2.powertrain.regen.full"
            icon = "garage_brakes"
          else
            title = "ui.radialmenu2.powertrain.regen.level"
            icon = "editor_number_" .. strength
            context = {level = strength, percent = math.floor(strength * 100 / maxStrength + 0.5)}
          end

          local e = {
            title = title,
            icon = icon,
            context = context,
            priority = priority,
            onSelect = function()
              electrics.values.regenStrength = strength
              return {"reload"}
            end
          }

          if (electrics.values.regenStrength or 0) == strength then
            e.color = "#ff6600"
          end

          table.insert(entries, e)
        end
      end
    }
  )

  -- cruise control
  addEntry({level = "/", title = "ui.radialmenu2.cruiseControl", priority = 50, ["goto"] = "/cruise_control/", icon = "cruise-control_cruise-enable"})

  addEntry(
    {
      level = "/cruise_control/",
      generator = function(entries)
        local cruiseEnabled = false
        local cruiseSetSpeed = 0
        if extensions.isExtensionLoaded("cruiseControl") then
          local config = extensions.cruiseControl.getConfiguration()
          cruiseEnabled = config.isEnabled
          cruiseSetSpeed = config.targetSpeed
        end

        local e

        -- Toggle cruise on/off
        e = {
          title = "ui.radialmenu2.cruiseControl.toggle",
          priority = 51,
          icon = "cruise-control_cruise-enable",
          onSelect = function()
            extensions.cruiseControl.setEnabled(not cruiseEnabled)
            return {"reload"}
          end
        }
        if cruiseEnabled then
          e.color = "#33ff33"
        end
        table.insert(entries, e)

        -- Resume/+
        e = {
          title = "ui.radialmenu2.cruiseControl.plusResume",
          priority = 52,
          icon = "cruise-control_plus-res",
          onSelect = function()
            if cruiseEnabled then
              local units = settings.getValue("uiUnitLength")
              local delta = units == "imperial" and constants.mphToMs or constants.kmhToMs

              extensions.cruiseControl.changeSpeed(delta)
            else
              extensions.cruiseControl.setSpeed(cruiseSetSpeed)
            end
            return {"reload"}
          end
        }
        table.insert(entries, e)

        -- Set/-
        e = {
          title = "ui.radialmenu2.cruiseControl.minusSet",
          priority = 53,
          icon = "cruise-control_minus-set",
          onSelect = function()
            if cruiseEnabled then
              local units = settings.getValue("uiUnitLength")
              local delta = units == "imperial" and constants.mphToMs or constants.kmhToMs

              extensions.cruiseControl.changeSpeed(-delta)
            else
              extensions.cruiseControl.holdCurrentSpeed()
            end
            return {"reload"}
          end
        }
        table.insert(entries, e)

        -- Cancel
        e = {
          title = "ui.radialmenu2.cruiseControl.cancel",
          priority = 54,
          icon = "cruise-control_cruise-disable",
          onSelect = function()
            extensions.cruiseControl.setEnabled(false)
            return {"reload"}
          end
        }
        table.insert(entries, e)
      end
    }
  )

  addEntry({level = "/", title = "ui.radialmenu2.funstuff", priority = 99, ["goto"] = "/funstuff/", icon = "material_tag_faces"})
  addEntry(
    {level = "/funstuff/", title = "ui.radialmenu2.funstuff.LatchesOpen", icon = "radial_vehicle_open_all", onSelect = function()
        for k, v in pairs(controller.getControllersByType("advancedCouplerControl")) do
          v.detachGroup()
        end
      end}
  )
  addEntry(
    {level = "/funstuff/", title = "ui.radialmenu2.funstuff.LatchesClose", icon = "radial_vehicle_doors_close", onSelect = function()
        for k, v in pairs(controller.getControllersByType("advancedCouplerControl")) do
          v.tryAttachGroupImpulse()
        end
      end}
  )

  addEntry(
    {level = "/", title = "ui.radialmenu2.Save", icon = "radial_save", priority = 90, onSelect = function()
        beamstate.save()
        return {"hide"}
      end}
  )
  addEntry(
    {
      level = "/",
      title = "ui.radialmenu2.Load",
      icon = "radial_load",
      priority = 91,
      onSelect = function()
        beamstate.load()
        obj:queueGameEngineLua("extensions.hook('trackVehReset')")
        return {"hide"}
      end
    }
  )

  --[[
  addEntry({ level = '/', title = 'entry by vehicle ' .. tostring(obj:getId()), onSelect = function() ui_message('Hello world from obj ' .. tostring(obj:getId())) end } )
  addEntry({ level = '/test/', title = 'do things for ' .. tostring(obj:getId())} )

  -- generator tests
  addEntry({ level = '/', generator = function(entries)
    table.insert(entries, { title = 'dynamic vehicle submenu', goto = '/test_dynamic2/'})
  end})

  addEntry({ level = '/test_dynamic2/', generator = function(entries)
    for i = 1, 10 do
      table.insert(entries, { title = 'dynamic entry ' .. tostring(i), onSelect = function() print('selected ' .. tostring(i)) end})
    end
  end})
]]
end

-- open the menu in a specific level
local function requestItems(level)
  --log('D', 'core_quickAccess.requestItems', 'requesting items for GE from id: ' .. tostring(obj:getId()) .. ' with M = ' .. tostring(M))
  currentMenuItems = {}

  local entries = deepcopy(menuTree[level] or {}) -- make a copy, the generators modify the menu below, this should not be persistent

  for _, e in pairs(entries) do
    if type(e) == "table" then
      if type(e.generator) == "function" then
        e.generator(entries)
      else
        table.insert(currentMenuItems, e)
      end
    end
  end

  --print('core_quickAccess.vehicleItemsCallback(' .. obj:getId() .. ',' .. serialize(currentMenuItems) .. ')')
  obj:queueGameEngineLua("core_quickAccess.vehicleItemsCallback(" .. obj:getId() .. "," .. serialize(level) .. "," .. serialize(currentMenuItems) .. ")")
  return true
end

local function itemSelectCallback(args)
  if args == nil then
    -- no result = hide by default
    args = {"hide"}
  end
  obj:queueGameEngineLua("core_quickAccess.vehicleItemSelectCallback(" .. obj:getId() .. "," .. serialize(args) .. ")")
end

local function selectItem(id)
  --print('selectItem > ' .. tostring(id))
  if type(id) ~= "number" then
    log("E", "core_quickAccess.selectItem", "id invalid: " .. tostring(id))
    itemSelectCallback({"error", "id_invalid"})
    return
  end
  if currentMenuItems == nil then
    log("E", "core_quickAccess.selectItem", "currentMenuItems empty")
    itemSelectCallback({"error", "id_invalid"})
    return
  end
  local item = currentMenuItems[id]
  if item == nil then
    log("E", "core_quickAccess.selectItem", "item not found: " .. tostring(id))
    return itemSelectCallback({"error", "item_not_found"})
  end

  -- actual action implementation
  if type(item["goto"]) == "string" then
    obj:queueGameEngineLua('core_quickAccess.pushTitle( "' .. item.title .. '", ' .. serialize(item.context or {}) .. " )")
    return itemSelectCallback({"goto", item["goto"]})
  elseif type(item.onSelect) == "function" then
    return itemSelectCallback(item.onSelect(item))
  end

  log("E", "core_quickAccess.itemAction", 'Item selected with idea on what to do. "onSelect" missing? ' .. dumps(item))
  itemSelectCallback({"error", "unknown_action"})
end

-- public interface

-- interface for GE lua
M.requestItems = requestItems
M.onExtensionLoaded = onExtensionLoaded
M.selectItem = selectItem -- no extension message hook, thus no 'on'

-- interface for the vehicle lua
M.addEntry = addEntry
M.registerMenu = function()
  log("E", "quickAccess", "registerMenu is deprecated. Please use core_quickAccess.addEntry: " .. debug.traceback())
end

return M
