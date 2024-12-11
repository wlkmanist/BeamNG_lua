-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"core_vehicleTriggers"}
local im = ui_imgui

local slowMoFactor = 0.01

-- holds all known menu items
local menuTree = {}
local menuTreeCopy
local menuTreeCopyForUI

local callStack = {} -- contains the history of menus so one can go 'back' or 'up' the menus again

-- transitional state: these values can change whereas the UI is not visible yet, use uiVisible to check if the UI is shown
local currentLevel = nil -- level that the menu is in right now
local currentMenuItems = nil -- items that are displaying
local uiVisible = false
local vehicleMenuTrees = {}
local currentUiState
local simTimeBefore
local possibleTopLevels = {"sandbox", "playerVehicle", "favorites"}
local categories = {
  "funStuff", "vehicles", "recovery", "ai", "environment",
  "general", "electrics", "couplers", "powertrain", "cruise_control",
}
local safeFile = "settings/radialFavorites.json"

-- TODO saving to file
-- TODO dynamically adding more favorite categories

local favoriteActions = {
  walkingMode = {
    [1] = {level = "/sandbox/recovery/", title = "ui.radialmenu2.Manage.Home"},
    [2] = {level = "/sandbox/recovery/", title = "ui.radialmenu2.Manage.Set_home"}
  },
  other = {
    [1] = {level = "/sandbox/recovery/", title = "ui.radialmenu2.Manage.Home"},
    [2] = {level = "/sandbox/recovery/", title = "ui.radialmenu2.Manage.Set_home"}
  },
}

local categoryData = {}

local navXVal = 0
local navYVal = 1

local vehicleWaitFrames = 0 -- counter for timeout waiting for vehicle menu items

local titles
local contexts
local function resetTitle()
  titles = {"ui.radialmenu2.main_menu"}
  contexts = {nil}
end

resetTitle()

local initialized = false

-- if its shown
local function isEnabled()
  return uiVisible
end

local function convertFavoriteActionsKeysToStrings(input, reverse)
  local result = {}
  for mode, modeActions in pairs(input) do
    result[mode] = {}
    for slotIndex, actionData in pairs(modeActions) do
      result[mode][reverse and tonumber(slotIndex) or tostring(slotIndex)] = actionData
    end
  end
  return result
end

local favoriteSelectionIndex
local function addActionToQuickAccess(level, title, index)
  local quickAccessTable = gameplay_walk.isWalking() and favoriteActions.walkingMode or favoriteActions.other
  quickAccessTable[index] = {level = level, title = title}
  M.reload()
  favoriteSelectionIndex = nil

  jsonWriteFile(safeFile, convertFavoriteActionsKeysToStrings(favoriteActions), true, nil, true)
end

local function removeActionFromQuickAccess(index)
  local quickAccessTable = gameplay_walk.isWalking() and favoriteActions.walkingMode or favoriteActions.other
  quickAccessTable[index] = nil
  M.reload()
  favoriteSelectionIndex = nil

  jsonWriteFile(safeFile, convertFavoriteActionsKeysToStrings(favoriteActions), true, nil, true)
end

local function buildTree(flatData)
  local tree = {items = {}, path = "/"}

  for path, value in pairs(flatData) do
    local currentNode = tree
    currentNode.items = currentNode.items or {}
    local currentPath = "/"
    for segment in string.gmatch(path, "[^/]+") do
      currentPath = currentPath .. segment .. "/"
      if not currentNode.items[segment] then
        currentNode.items[segment] = {items = {}, path = currentPath, niceName = M.toNiceName(segment)}
      end
      currentNode = currentNode.items[segment]
    end

    -- Add the final value to the leaf node
    for k, v in pairs(value) do
      v.level = path -- Assign the full path to the leaf node
      v.action = true
      currentNode.items[v.title] = v
    end
  end

  return tree
end

local function addTitleToTreeItems(tree)
  for key, value in pairs(tree.items) do
    if value.path then
      for key2, value2 in pairs(tree.items) do
        if value2["goto"] and value2["goto"] == value.path then
          tableMerge(value, value2)
          tree.items[key2] = nil
          break
        end
      end
    end
    if value.items then
      addTitleToTreeItems(value)
    end
  end
end

local function openFavoriteSelection(index)
  favoriteSelectionIndex = index
  menuTreeCopyForUI = buildTree(deepcopy(menuTreeCopy))
  menuTreeCopyForUI.items.favorites = nil
  menuTreeCopyForUI.items.options = {removeAction = true}

  addTitleToTreeItems(menuTreeCopyForUI)

  guihooks.trigger('OpenRadialFavoriteSelectionPrompt')
end

local function getFavoriteSelectionUIData()
  local data = {
    items = menuTreeCopyForUI,
    slotIndex = favoriteSelectionIndex
  }
  return data
end

local function getActionInfo(level, title)
  for _, actionInfo in ipairs(menuTreeCopy[level]) do
    if actionInfo.title == title then return actionInfo end
  end
end

local function toNiceName(str)
  -- Replace underscores with spaces
  local niceName = str:gsub("_", " ")

  -- Add space before each capital letter except the first one
  niceName = niceName:gsub("(%l)(%u)", "%1 %2")

  -- Capitalize the first letter of each word
  niceName = niceName:gsub("(%a)(%w*)", function(first, rest)
    return first:upper() .. rest:lower()
  end)

  return niceName
end

local function addCategoryData(topLevel, category, data)
  categoryData[topLevel] = categoryData[topLevel] or {}
  data.id = data.id or category
  data.niceName = data.niceName or toNiceName(category)
  categoryData[topLevel][category] = data
end

local function sort_categories(input_list)
  -- Create a lookup table for quick index access
  local category_index = {}
  for i, category in ipairs(categories) do
    category_index[category] = i
  end

  -- Sort the input list based on the category order
  table.sort(input_list, function(a, b)
    local index_a = category_index[a.id]
    local index_b = category_index[b.id]

    -- If both are in the category list, compare by index
    if index_a and index_b then
      return index_a < index_b
    end

    -- If only one is in the category list, it takes precedence
    if index_a then
      return true
    elseif index_b then
      return false
    end

    -- If neither is in the category list, sort alphabetically
    return a.id < b.id
  end)
end

local function getAllLevels(path)
  local levels = {}
  local currentPath = "/"

  for segment in path:gmatch("/([^/]+)") do
    currentPath = currentPath .. segment .. "/"
    table.insert(levels, currentPath)
  end

  return levels
end

local function gotoButtonExists(gotoLevel, prevLevel, menuTreeCopy)
  if not menuTreeCopy[prevLevel] then return false end
  for _, item in ipairs(menuTreeCopy[prevLevel]) do
    if item.goto == gotoLevel then return true end
  end
end

--[[
- definition:
 * items = items inside a menu
 * entries : a single thing that should produce one ore more menu entries
]]

-- this function adds a new menu entry
local function addEntry(_args)
  local args = deepcopy(_args) -- do not modify the outside table by any chance
  if  type(args.generator) ~= 'function' and (type(args.title) ~= 'string' or (type(args.onSelect) ~= 'function' and type(args["goto"]) ~= 'string')) then
    -- TODO: add proper warning/error
    log('W', 'quickaccess', 'Menu item needs at least a title and an onSelect function callback: ' .. dumps(args))
    --return false
  end

  -- defaults
  if args.level == nil then args.level = '/sandbox/general' end
  if args.desc == nil then args.desc = '' end

  -- add the entry to "sandbox" if the given top level doesnt exist (like for old mods)
  local topLevelId = args.level:match("^/([^/]+)/")
  if not tableContains(possibleTopLevels, topLevelId) then
    args.level = "/sandbox" .. args.level
  end

  if type(args.level) ~= 'string' then
    log('E', 'quickaccess', 'Menu item level incorrect, needs to be a string: ' .. dumps(args))
    return false
  end
  if string.sub(args.level, string.len(args.level)) ~= '/' then args.level = args.level .. '/' end -- make sure there is always a trailing slash in the level

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

local function pushTitle(t, c)
  table.insert(titles, t)
  table.insert(contexts, c)
end

local function registerDefaultMenus()
  -- switch to other vehicles
  addEntry({ level = '/sandbox/vehicles/', generator = function(entries)
    if not core_input_actionFilter.isActionBlocked("switch_next_vehicle") then
      if be:getObjectCount() > 0 then
        table.insert(entries,{ level = '/vehicles/', title = 'ui.radialmenu2.Manage.Remove', icon='material_delete_forever', onSelect = function() core_vehicles.removeCurrent() extensions.hook("trackNewVeh") return {'hide'} end} )
        table.insert(entries,{ level = '/vehicles/', title = 'ui.radialmenu2.Manage.Clone', icon='radial_clone', onSelect = function() core_vehicles.cloneCurrent() extensions.hook("trackNewVeh") return {'hide'} end} )
      end

      if be:getObjectCount() < 2 then
        return
      elseif be:getObjectCount() == 2 then
        table.insert(entries, { title = 'ui.radialmenu2.Manage.Switch', icon = 'material_swap_horiz', onSelect = function()
          be:enterNextVehicle(0, 1)
          return {'reload'}
        end})
      elseif be:getObjectCount() > 2 then
        table.insert(entries, { title = 'ui.radialmenu2.Manage.Switch', icon = 'material_swap_horiz', ["goto"] = '/sandbox/vehicles/switch_vehicles/'})
      end
    end
  end})

  -- vehicle list menu
  addEntry({ level = '/sandbox/vehicles/switch_vehicles/', icon = 'radial_switch', generator = function(entries)
    if be:getObjectCount() == 0 or core_input_actionFilter.isActionBlocked("switch_next_vehicle") then return end
    local vid = be:getPlayerVehicleID(0) or -1 -- matches all

    local function switchToVehicle(objid)
      local veh = be:getObjectByID(objid)
      if veh then
        be:enterVehicle(0, veh)
        return true
      end
    end

    for i = 0, be:getObjectCount()-1 do
      local veh = be:getObject(i)
      if veh:getId() ~= vid then
        local vehicleName = veh:getJBeamFilename()
        local vehicleNameSTR = vehicleName --default name use jbeam folder
        local filePath = "/vehicles/"..vehicleName.."/info.json"
        local vicon = "material_directions_car"
        if FS:fileExists(filePath) then --check for main info
          local mainInfo = jsonReadFile(filePath)
          veh = scenetree.findObjectById(veh:getId())
          local vehConfig = string.match(veh.partConfig, "([^./]*).pc")
          if veh.partConfig:sub(1,1) == "{" or veh.partConfig:sub(1,1) == "[" then
            vehConfig = "*custom*"
          elseif not vehConfig or string.len(vehConfig) ==0 then
            vehConfig = mainInfo["default_pc"]
            if vehConfig == nil then vehConfig = "" end
          end
          filePath = "/vehicles/"..vehicleName.."/info_"..(vehConfig or "")..".json"
          if FS:fileExists(filePath) then --check info of pc
            local InfoConfig = jsonReadFile(filePath)
            if InfoConfig["Type"]=="PropParked" or InfoConfig["Type"]=="PropTraffic" then goto skipObj end
            vehicleNameSTR = mainInfo["Name"] .. "\\n" .. (InfoConfig["Configuration"] or "")
          else
            vehicleNameSTR = mainInfo["Name"] .. "\\n" .. vehConfig
          end
          -- if not FS:fileExists(vicon) then vicon = "material_directions_car" end --if picture doesn't exist, avoid nasty CEF no picture
          if mainInfo["Type"] then
            if mainInfo["Type"]== "Trailer" then vicon = "radial_couplers" end
            if mainInfo["Type"]== "Prop" then vicon = "radial_prop" end
          end
        end
        local objid = veh:getId()
        table.insert(entries, {
          title = vehicleNameSTR,
          icon = vicon,
          onSelect = function()
            switchToVehicle(objid)
            return {'reload'}
          end
        })
      end
      ::skipObj::
    end
  end
  })

  -- manage menu
  addEntry({ level = '/sandbox/environment/blab/asdasd/uuuu/', generator = function(entries)
    for i = 0, 7 do
      local e = {title = "asd" .. i, onSelect = function()return {''} end}
      table.insert(entries, e)
    end
  end})

  addEntry({ level = '/playerVehicle/general/', generator = function(entries)
    if not getPlayerVehicle(0) then return end
    local driverNode = core_camera.getDriverData(getPlayerVehicle(0)) or 0
    local driverPos = getPlayerVehicle(0):getPosition() + getPlayerVehicle(0):getNodePosition(driverNode)
    local vehIds = {}
    local triggerEntries = {}

    for i = 0, be:getObjectCount() - 1 do
      local veh = be:getObject(i)
      local vehId = veh:getId()
      local vData = extensions.core_vehicle_manager.getVehicleData(vehId)
      if vData and vData.vdata and type(vData.vdata.triggers) == 'table' then
        for _, trg in pairs(vData.vdata.triggers or {}) do
          local trigger = veh:getTrigger(trg.abid)
          local triggerPos = trigger:getCenter()
          if triggerPos:distance(driverPos) < 2 then
            vehIds[vehId] = true
            local e = {title = trg.name, titleWithVehicleName = vData.vdata.information.name .. " " .. trg.name,
            onSelect = function()
              core_vehicleTriggers.triggerEvent("action0", 1, trg.abid, vehId, vData.vdata)
              return {'temporaryHide'}
            end,
            onDeselect = function()
              core_vehicleTriggers.triggerEvent("action0", 0, trg.abid, vehId, vData.vdata)
              return {'temporaryUnhide'}
            end,
            onSecondarySelect = function()
              core_vehicleTriggers.triggerEvent("action2", 1, trg.abid, vehId, vData.vdata)
              return {'temporaryHide'}
            end,
            onSecondaryDeselect = function()
              core_vehicleTriggers.triggerEvent("action2", 0, trg.abid, vehId, vData.vdata)
              return {'temporaryUnhide'}
            end}
            table.insert(triggerEntries, e)
          end
        end
      end
    end

    -- if there are triggers by multiple vehicles nearby, add the name of the vehicle as well
    for _, triggerEntry in ipairs(triggerEntries) do
      if tableSize(vehIds) > 1 then
        triggerEntry.title = triggerEntry.titleWithVehicleName
      end
      triggerEntry.titleWithVehicleName = nil
      table.insert(entries, triggerEntry)
    end
  end})

  addEntry({ level = '/sandbox/vehicles/', generator = function(entries)
    if not core_input_actionFilter.isActionBlocked("vehicle_selector") then
      local e = {title = 'ui.radialmenu2.Manage.Select', icon = 'material_directions_car',  onSelect = function() guihooks.trigger('ChangeState', {state = 'menu.vehicles'}) ; return {''} end}
      table.insert(entries, e)
    end
  end})

  addEntry({ level = '/sandbox/funStuff/', generator = function(entries)
    if not core_input_actionFilter.isActionBlocked("forceField") then
      local e = {title = 'ui.radialmenu2.funstuff.ForceField', icon = 'radial_boom',  onSelect = function() extensions.gameplay_forceField.toggleActive() return {"reload"} end}
      if extensions.gameplay_forceField.isActive() then e.color = '#ff6600' end
      table.insert(entries, e)
    end
    if not core_input_actionFilter.isActionBlocked("funBreak") then
      local e = {title = "ui.radialmenu2.funstuff.Break", icon = 'radial_break', onSelect = function() getPlayerVehicle(0):queueLuaCommand("beamstate.breakAllBreakgroups()") return {"hide"} end}
      table.insert(entries, e)
    end
    if not core_input_actionFilter.isActionBlocked("funHinges") then
      local e = {title = "ui.radialmenu2.funstuff.Hinges", icon = 'radial_hinges', onSelect = function() getPlayerVehicle(0):queueLuaCommand("beamstate.breakHinges()") return {"hide"} end}
      table.insert(entries, e)
    end
    if not core_input_actionFilter.isActionBlocked("funTires") then
      local e = {title = "ui.radialmenu2.funstuff.Tires", icon = 'garage_wheels', onSelect = function() getPlayerVehicle(0):queueLuaCommand("beamstate.deflateTires()") return {"hide"} end}
      table.insert(entries, e)
    end
    if not core_input_actionFilter.isActionBlocked("funFire") then
      local e = {title = "ui.radialmenu2.funstuff.Fire", icon = 'radial_fire', onSelect = function() getPlayerVehicle(0):queueLuaCommand("fire.igniteVehicle()") return {"hide"} end}
      table.insert(entries, e)
    end
    if not core_input_actionFilter.isActionBlocked("funExtinguish") then
      local e = {title = "ui.radialmenu2.funstuff.Extinguish", icon = 'radial_estinguish', onSelect = function() getPlayerVehicle(0):queueLuaCommand("fire.extinguishVehicle()") return {"hide"} end}
      table.insert(entries, e)
    end
    if not core_input_actionFilter.isActionBlocked("funBoom") then
      local e = {title = "ui.radialmenu2.funstuff.Boom", icon = 'radial_boom', onSelect = function() getPlayerVehicle(0):queueLuaCommand("fire.explodeVehicle()") return {"hide"} end}
      table.insert(entries, e)
    end
  end})

  addEntry({ level = "/sandbox/ai/", generator = function(entries)
    if not core_input_actionFilter.isActionBlocked("toggleAITraffic") and getPlayerVehicle(0) and be:getObjectCount() > 1 then -- more vehicles than the player exist
      table.insert(
        entries,
        {
          title = "ui.radialmenu2.ai.stop",
          priority = 61,
          icon = "radial_stop",
          onSelect = function()
            core_vehicleBridge.executeAction(getPlayerVehicle(0),'setOtherVehiclesAIMode', "stop")
            return {"hide"}
          end
        }
      )
      table.insert(
        entries,
        {
          title = "ui.radialmenu2.ai.random",
          priority = 62,
          icon = "radial_random",
          onSelect = function()
            core_vehicleBridge.executeAction(getPlayerVehicle(0),'setOtherVehiclesAIMode', "random")
            return {"hide"}
          end
        }
      )
      table.insert(
        entries,
        {
          title = "ui.radialmenu2.ai.flee",
          priority = 64,
          icon = "radial_flee",
          onSelect = function()
            core_vehicleBridge.executeAction(getPlayerVehicle(0),'setOtherVehiclesAIMode', "flee")
            return {"hide"}
          end
        }
      )
      table.insert(
        entries,
        {
          title = "ui.radialmenu2.ai.chase",
          priority = 65,
          icon = "radial_chase_me",
          onSelect = function()
            core_vehicleBridge.executeAction(getPlayerVehicle(0),'setOtherVehiclesAIMode', "chase")
            return {"hide"}
          end
        }
      )
      table.insert(
        entries,
        {
          title = "ui.radialmenu2.ai.follow",
          priority = 66,
          icon = "radial_followme",
          onSelect = function()
            core_vehicleBridge.executeAction(getPlayerVehicle(0),'setOtherVehiclesAIMode', "follow")
            return {"hide"}
          end
        }
      )
    end
  end})

  addEntry({ level = '/sandbox/ai/', generator = function(entries)
    table.insert(entries, { title = 'ui.radialmenu2.traffic', priority = 53, ["goto"] = '/sandbox/ai/traffic/', icon = 'material_traffic' })
  end})

  addEntry({ level = '/sandbox/ai/traffic/', generator = function(entries)
    if not core_input_actionFilter.isActionBlocked("toggleTraffic") then
      table.insert(entries, { title = 'ui.radialmenu2.traffic.stop', priority = 61, icon = 'radial_stop', onSelect = function()
        extensions.gameplay_traffic.deactivate(true)
        extensions.hook("stopTracking", ({Name = "TrafficEnabled"}))
        return {"hide"}
      end})
      table.insert(entries, { title = 'ui.radialmenu2.traffic.remove', priority = 62, icon = 'material_delete', onSelect = function()
        extensions.gameplay_parking.deleteVehicles()
        extensions.gameplay_traffic.deleteVehicles()
        extensions.hook("stopTracking", ({Name = "TrafficEnabled"}))
        return {"hide"}
      end})
      table.insert(entries, { title = 'ui.radialmenu2.traffic.spawnNormal', priority = 63, icon = 'material_directions_car', onSelect = function()
        extensions.gameplay_traffic.setupTrafficWaitForUi(false)
        extensions.hook("startTracking", ({Name = "TrafficEnabled"}))
        return {"hide"}
      end})
      table.insert(entries, { title = 'ui.radialmenu2.traffic.spawnPolice', priority = 64, icon = 'radial_chase_me', onSelect = function()
        extensions.gameplay_traffic.setupTrafficWaitForUi(true)
        extensions.hook("startTracking", ({Name = "TrafficEnabled"}))
        return {"hide"}
      end})
      if be:getObjectCount() > 1 then
        table.insert(entries, { title = 'ui.radialmenu2.traffic.start', priority = 65, icon = 'material_play_circle_filled', onSelect = function()
          extensions.gameplay_traffic.activate()
          extensions.gameplay_traffic.setTrafficVars({aiMode = "traffic", enableRandomEvents = true})
          extensions.hook("startTracking", ({Name = "TrafficEnabled"}))
          return {"hide"}
        end})
      end
    end
  end})

  addEntry({ level = '/sandbox/recovery/', generator = function(entries)
    if getPlayerVehicle(0) and not core_input_actionFilter.isActionBlocked("reload_vehicle") then
      table.insert(entries, {
        title = "ui.radialmenu2.Save",
        icon = "radial_save",
        priority = 90,
        onSelect = function()
          getPlayerVehicle(0):queueLuaCommand("beamstate.save()")
          return {"hide"}
        end
      })

      table.insert(entries, {
        title = "ui.radialmenu2.Load",
        icon = "radial_load",
        priority = 91,
        onSelect = function()
          getPlayerVehicle(0):queueLuaCommand("beamstate.load()")
          extensions.hook('trackVehReset')
          return {"hide"}
        end
      })
    end

    if getPlayerVehicle(0) then
      if not core_input_actionFilter.isActionBlocked("loadHome") then
        local e = {title = 'ui.radialmenu2.Manage.Home', icon = 'radial_home', priority = 80, onSelect = function() extensions.hook('trackVehReset') getPlayerVehicle(0):queueLuaCommand("recovery.loadHome()") return {'hide'} end}
        table.insert(entries, e)
      end

      if not core_input_actionFilter.isActionBlocked("saveHome") then
        local e = {title = 'ui.radialmenu2.Manage.Set_home', icon = 'radial_set_home', priority = 81, onSelect = function() getPlayerVehicle(0):queueLuaCommand("recovery.saveHome()") return {'hide'} end}
        table.insert(entries, e)
      end
    end
  end})

  addEntry({ level = '/playerVehicle/general/', generator = function(entries)
    if getPlayerVehicle(0) and settings.getValue('GraphicDynMirrorsEnabled') and not core_input_actionFilter.isActionBlocked("switch_camera_next") then
      table.insert(entries, {
        title = "ui.radialmenu2.Mirrors",
        icon = "mirrorInteriorMiddle",
        priority = 95,
        onSelect = function()
          M.setEnabled(false)
          guihooks.trigger('ChangeState', {state = 'menu.vehicleconfig.tuning.mirrors', params = {exitRoute = "play"}})
          return {}
        end
      })
    end
  end})
end

local function getUniqueCategories(menuTree, firstLevel)
  local elements = {}  -- To track unique elements

  for key, _ in pairs(menuTree) do
    -- Split the key by "/" and get the second part (the second element after the initial "/" and the first element)
    local secondElement = key:match("^/" .. firstLevel .. "/([^/]+)/")
    if secondElement then
      elements[secondElement] = true
    end
  end
  return elements
end

local function countLevels(path)
  local count = 0
  for _ in path:gmatch("/[^/]+") do
    count = count + 1
  end
  return count
end

local uiData
-- we got all the data required, show the menu
local function _assembleMenuComplete()
  if not currentMenuItems then return end

  local objID = be:getPlayerVehicleID(0)
  local currentTopLevelId = currentLevel:match("^/([^/]+)/")
  local currentSecondLevelId = currentLevel:match("^/[^/]+/([^/]+)/")

  -- sort the entries
  --[[ table.sort(currentMenuItems, function(a, b)
    if a.priority == b.priority then
      if type(a.title) == 'string' and type(b.title) == 'string' then
        return a.title:upper() < b.title:upper()
      end
      -- no title, put at the end
      return 99
    end
    -- prevent nils
    local av = a.priority
    if av == nil then av = 999 end
    local bv = b.priority
    if bv == nil then bv = 999 end
    return av < bv
  end) ]]

  local backButtonIndex
  if #callStack > 0 then
    local mid = math.floor(#currentMenuItems/2)+1
    backButtonIndex = mid
  end

  local totalSize = 0
  for _, e in ipairs(currentMenuItems) do
    if e.enabled == nil then e.enabled = true end
    if e.size == nil then e.size = 1 end
    totalSize = totalSize + e.size
  end

  local radianTotal = 0
  for _, e in ipairs(currentMenuItems) do
    e.radianLower = radianTotal
    local radianSize = (e.size / totalSize) * 2*math.pi
    radianTotal = radianTotal + radianSize
    e.radianUpper = radianTotal
  end

  local categoriesList = {}
  local categoriesFromMenu = getUniqueCategories(menuTreeCopy, currentTopLevelId)
  for categoryFromMenu, _ in pairs(categoriesFromMenu) do
    if categoryData[currentTopLevelId] and categoryData[currentTopLevelId][categoryFromMenu] then
      table.insert(categoriesList, categoryData[currentTopLevelId][categoryFromMenu])
    else
      table.insert(categoriesList, {
        id = categoryFromMenu,
        niceName = toNiceName(categoryFromMenu)
      })
    end
  end

  sort_categories(categoriesList)

  uiVisible = true
  uiData = {
    canGoBack = #callStack > 0,
    items = currentMenuItems,
    title = titles,
    context = contexts,
    categories = categoriesList,
    currentTopLevelId = currentTopLevelId,
    selectedCategory = currentSecondLevelId,
    backButtonIndex = backButtonIndex,
    currentLevel = currentLevel
  }

  simTimeBefore = simTimeBefore or simTimeAuthority.get()
  simTimeAuthority.set(slowMoFactor)

  guihooks.trigger('ChangeState', {state ='Radial'})
  guihooks.trigger('radialMenuUpdated')
end

local function getUiData()
  return uiData
end

local function isMenuEmpty(level)
  local entries = deepcopy(menuTreeCopy[level] or {}) -- make a copy, the generators modify the menu below, this should not be persistent
  local menuItems = {}

  for _, e in ipairs(entries) do
    if type(e) == 'table' then
      if type(e.generator) == 'function' then
        e.generator(entries)
      else
        table.insert(menuItems, e)
      end
    end
  end

  for _, menuItem in ipairs(menuItems) do
    if not (menuItem["goto"] or menuItem.generator) then
      return false
    end
  end

  for _, menuItem in ipairs(menuItems) do
    if menuItem["goto"] and not isMenuEmpty(menuItem["goto"]) then
      return false
    end
  end

  return true
end

local function generateCompleteTree(level)
  local menuTreeCopy = deepcopy(menuTree)
  currentMenuItems = {}

  for path, items in pairs(menuTreeCopy) do
    for _, e in ipairs(items) do
      if type(e) == "table" then
        if type(e.generator) == "function" then
          e.generator(items)
        end
      end
    end
  end

  for path, items in pairs(menuTreeCopy) do
    for i = #items, 1, -1 do
      local item = items[i]
      if item.generator then
        table.remove(items, i)
      end
    end
  end

  return menuTreeCopy
end

-- open the menu in a specific level
local function show(level, getVehicleItems)
  if getVehicleItems == nil then getVehicleItems = true end
  if type(level) ~= 'string' then level = '/sandbox/recovery/' end -- default to the root

  if level == '/sandbox/recovery/' then
    resetTitle()
  end

  currentLevel = level

  -- now ask the active vehicle for any items
  local vehicle = getPlayerVehicle(0)
  if vehicle and getVehicleItems then
    vehicle:queueLuaCommand('extensions.core_quickAccessNew.requestItems("' .. tostring(currentLevel) .. '")')
    -- we give the vehicle 4 gfx frames to add items
    vehicleWaitFrames = 4
    return
  end

  extensions.hook("onBeforeRadialOpened")

  menuTreeCopy = generateCompleteTree(currentLevel)

  local playerVehId = be:getPlayerVehicleID(0)
  if playerVehId then
    for k, vehicleLevel in pairs(vehicleMenuTrees[playerVehId]) do
      if menuTreeCopy[k] then
        for _, item in ipairs(vehicleLevel) do
          table.insert(menuTreeCopy[k], item)
        end
      else
        menuTreeCopy[k] = vehicleLevel
      end
    end
  end

  -- add any missing "goto" buttons
  ::gotoButtonsStart::
  for levelPath, levelInfo in pairs(menuTreeCopy) do
    if countLevels(levelPath) >= 3 then
      local allLevels = getAllLevels(levelPath)
      for i, subLevel in ipairs(allLevels) do
        if i > 1 then
          local nextLevel = allLevels[i+1]
          if nextLevel then
            if not gotoButtonExists(nextLevel, subLevel, menuTreeCopy) then
              local item = {
                goto = nextLevel,
                icon = "material_traffic",
                priority = 53,
                title = toNiceName(nextLevel:match("/([^/]+)/?$"))
              }
              menuTreeCopy[subLevel] = menuTreeCopy[subLevel] or {}
              table.insert(menuTreeCopy[subLevel], item)
              goto gotoButtonsStart
            end
          end
        end
      end
    end
  end

  -- Add the favorite menu and buttons
  local favoriteActionsCurrent = gameplay_walk.isWalking() and favoriteActions.walkingMode or favoriteActions.other
  menuTreeCopy["/favorites/favorite1/"] = {}
  for i = 1, 8 do
    if favoriteActionsCurrent[i] then
      local favorite = favoriteActionsCurrent[i]
      local actionInfo = getActionInfo(favorite.level, favorite.title)

      -- if the action is not found, add a disabled one
      if not actionInfo then
        actionInfo = {
          title = favorite.title,
          enabled = false
        }
      end
      table.insert(menuTreeCopy["/favorites/favorite1/"], actionInfo)
    else
      -- TODO not sure if it's a problem when multiple buttons have the same name
      local item = {title = "Empty slot " .. i, onSelect = function() return {''} end}
      table.insert(menuTreeCopy["/favorites/favorite1/"], item)
    end
  end

  for _, item in ipairs(menuTreeCopy[currentLevel] or {}) do
    table.insert(currentMenuItems, item)
  end

  -- remove "goto" buttons that only lead to empty menues
  for i = #currentMenuItems, 1, -1 do
    local item = currentMenuItems[i]
    if item["goto"] then
      if isMenuEmpty(item["goto"]) then
        table.remove(currentMenuItems, i)
      end
    end
  end

  _assembleMenuComplete()

  return true
end

local function vehicleItemsCallback(objID, level, vehicleMenuTree)
  if currentLevel == nil then
    return
  end

  vehicleMenuTrees[objID] = vehicleMenuTree

  -- no need to wait anymore
  vehicleWaitFrames = 0
  show(level, false)
end

-- go to another level, saving the history
local function gotoLevel(level)
  if currentLevel ~= nil then
    table.insert(callStack, currentLevel)
  end
  return show(level)
end

local function hide()
  extensions.hook("onHideRadialMenu")
  if uiVisible then
    guihooks.trigger('ChangeState', {state ='play'})
  end
  currentMenuItems = nil
  currentLevel = nil
  vehicleWaitFrames = 0
  uiVisible = false

  if simTimeBefore then
    simTimeAuthority.set(simTimeBefore)
    simTimeBefore = nil
  end

  resetTitle()
end

local function reload()
  if currentLevel then show(currentLevel) end
end

local function back()
  if currentLevel == nil then return end -- not visible: no way to go back, return
  if not callStack or #callStack == 0 then
    -- at top to the history: close?
    --return hide()
    return false
  end

  table.remove(titles, #titles)
  table.remove(contexts, #contexts)
  local oldLevel = callStack[#callStack]
  table.remove(callStack, #callStack)
  show(oldLevel)
end

local function temporaryHide()
  guihooks.trigger('RadialTemporaryHide', true)
  simTimeAuthority.set(1)
end

local function temporaryUnhide()
  guihooks.trigger('RadialTemporaryHide', false)
  simTimeAuthority.set(slowMoFactor)
end

local function itemSelectCallback(actionResult)
  log('D', 'quickaccess.itemSelectCallback', 'called: ' .. dumps(actionResult))
  if type(actionResult) ~= 'table' then
    log('E', 'quickaccess.itemSelectCallback', 'invalid item result args: ' .. dumps(actionResult))
    return
  end
  if actionResult[1] == 'hide' then
    hide()
  elseif actionResult[1] == 'reload' then
    reload()
  elseif actionResult[1] == 'goto' then
    gotoLevel(actionResult[2])
  elseif actionResult[1] == 'back' then
    back()
  elseif actionResult[1] == 'hideMeOnly' then
    hide()
  elseif actionResult[1] == 'temporaryHide' then
    temporaryHide()
  elseif actionResult[1] == 'temporaryUnhide' then
    temporaryUnhide()
  end
end

local function itemAction(item, buttonDown, actionIndex)
  if item == nil then return end

  -- remote item? call vehicle then
  if item.objID then
    local veh = be:getObjectByID(item.objID)
    if not veh then
      log('E', 'quickaccess', 'unable to select item. vehicle got missing: ' .. tostring(objID) .. ' - menu item: ' .. dumps(item))
      return
    end
    veh:queueLuaCommand('extensions.core_quickAccessNew.selectItem(' .. serialize(item.id) .. ', ' .. serialize(buttonDown) .. ', ' .. serialize(actionIndex) .. ')')
    return
  end

  if buttonDown then
    -- goto = dive into this new sub menu
    if type(item["goto"]) == 'string' and actionIndex == 1 then
      table.insert(titles, item.title)
      itemSelectCallback({'goto', item["goto"]})
      return true
    elseif type(item.onSelect) == 'function' and actionIndex == 1 then
      itemSelectCallback(item.onSelect(item))
    elseif type(item.onSecondarySelect) == 'function' and actionIndex == 2 then
      itemSelectCallback(item.onSecondarySelect(item))
    elseif type(item.onTertiarySelect) == 'function' and actionIndex == 3 then
      itemSelectCallback(item.onTertiarySelect(item))
    end
  else
    if type(item.onDeselect) == 'function' and actionIndex == 1 then
      itemSelectCallback(item.onDeselect(item))
    elseif type(item.onSecondaryDeselect) == 'function' and actionIndex == 2 then
      itemSelectCallback(item.onSecondaryDeselect(item))
    elseif type(item.onTertiaryDeselect) == 'function' and actionIndex == 3 then
      itemSelectCallback(item.onTertiaryDeselect(item))
    end
  end
  return true
end

local function onInit()
  if not initialized then
    registerDefaultMenus()
    initialized = true
  end
  hide()
end

-- callback from the
local function selectItem(id, buttonDown, actionIndex)
  if type(id) ~= 'number' then return end
  if currentMenuItems == nil then return end
  local m = currentMenuItems[id]
  if m == nil then
    log('E', 'quickAccess.selectItem', 'item not found: ' .. tostring(id))
  end
  actionIndex = actionIndex or 1
  itemAction(m, buttonDown, actionIndex)
end


-- TODO enable RadialMenuActionMap when we switch to new radial menu
local function setEnabled(enabled, level)
  if enabled then
    if not currentUiState or currentUiState == "play" or uiVisible then
      --scenetree.findObject("RadialMenuActionMap"):push()
      callStack = {} -- reset the callstack
      show(level)
    end
  else
    --scenetree.findObject("RadialMenuActionMap"):pop()
    hide()
  end
end

local function toggle(level)
  if isEnabled() then
    setEnabled(false)
  else
    setEnabled(true, level)
  end
end

local lastTimeMoved = 0
local function getMovedRadialLastTimeMs()
  return lastTimeMoved
end

local function moved()
  lastTimeMoved = Engine.Platform.getSystemTimeMS()
end

local function renderTree(node, path)
  for key, value in pairs(node) do
    local currentPath = (path and (path .. "/" .. key) or key)
    if type(value) == "table" then
      local isLowestLevel = true
      local title = key -- Default title as key

      -- Check if the current node is a lowest-level table and extract the title if available
      for subKey, subValue in pairs(value) do
        if type(subValue) == "table" then
          isLowestLevel = false
          break
        elseif subKey == "title" then
          title = subValue
        end
      end

      if isLowestLevel then
        im.Text(title)
        im.SameLine()
        if im.Button("Add ##" .. currentPath) then
          addActionToQuickAccess("/" .. path .. "/", title, favoriteSelectionIndex)
        end
      else
        if im.CollapsingHeader1(key) then
          im.Indent() -- Add indentation for child elements
          renderTree(value, currentPath)
          im.Unindent() -- Remove indentation after rendering child elements
        end
      end
    end
  end
end

local function renderImGuiTreeWindow()
  if im.Begin("Favorite Selection") then
    renderTree(menuTreeCopyForUI, nil)

    if im.Button("Cancel") then
      favoriteSelectionIndex = nil
    end
  end
  im.End()
end

local function onUpdate()
  -- logic for the menu assembling timeout
  if vehicleWaitFrames > 0 then
    vehicleWaitFrames = vehicleWaitFrames - 1
    if vehicleWaitFrames == 0 then
      log('E', 'quickaccess', 'vehicle didn\'t respond in time with menu items, showing menu anyways ...')
      _assembleMenuComplete()
    end
  end

  --[[ if favoriteSelectionIndex then
    renderImGuiTreeWindow()
  end ]]
end

local function vehicleItemSelectCallback(objID, args)
  log('D', 'quickAccess.vehicleItemSelectCallback', 'got result from id: ' .. tostring(objID) .. ' : ' .. dumps(args))
  --we don't need objID for now
  itemSelectCallback(args)
end

local function onVehicleSwitched()
  -- if switchign vehicles while the menu is show, reload it
  if uiVisible and currentLevel then
    reload()
  end
end

local function onExtensionLoaded()
  extensions.hook("onQuickAccessLoaded")

  addCategoryData("playerVehicle", "powertrain", {icon = "mirrorInteriorMiddle"})

  local savedFavoriteActions = jsonReadFile(safeFile)
  if savedFavoriteActions then
    favoriteActions = convertFavoriteActionsKeysToStrings(savedFavoriteActions, true)
    log("I","","Loaded radial menu favorites")
  end
end

local function onUiChangedState(toState)
  currentUiState = toState
end

local function onSerialize()
  setEnabled(false)
end

-- public interface
M.onInit = onInit
M.vehicleItemsCallback = vehicleItemsCallback
M.vehicleItemSelectCallback = vehicleItemSelectCallback
M.onUpdate = onUpdate
M.onVehicleSwitched = onVehicleSwitched
M.onExtensionLoaded = onExtensionLoaded
M.onUiChangedState = onUiChangedState
M.onSerialize = onSerialize
M.pushTitle = pushTitle
M.resetTitle = resetTitle
M.getUiData = getUiData
M.openFavoriteSelection = openFavoriteSelection

-- public API
M.addEntry = addEntry
M.registerMenu = function() log('E', 'quickAccess', 'registerMenu is deprecated. Please use quickAccess.addEntry: ' .. debug.traceback()) end

-- API towards the UI
M.selectItem = selectItem
M.back = back
M.isEnabled = isEnabled
M.moved = moved
M.getMovedRadialLastTimeMs = getMovedRadialLastTimeMs
M.reload = reload
M.getFavoriteSelectionUIData = getFavoriteSelectionUIData
M.addActionToQuickAccess = addActionToQuickAccess
M.removeActionFromQuickAccess = removeActionFromQuickAccess
M.toNiceName = toNiceName

-- input map
M.setEnabled = setEnabled
M.toggle = toggle

return M
