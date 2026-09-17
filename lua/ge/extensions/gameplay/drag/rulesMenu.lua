-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {}

local currentFacility = nil
local dragData = nil
local tether = nil
local menuOpen = false
local POI_RADIUS = 12

-- local presetManager
-- No persistence, just returns/accepts the supplied defaults so the rules menu keeps working.
local presetManagerFallback = {
  getPreset = function(levelId, stripId) return nil end,
  getOrCreatePreset = function(levelId, stripId, defaultsFromStrip)
    local def = defaultsFromStrip or {}
    return {
      dragType = def.dragType or "headsUpRace",
      treeType = def.treeType or ".500",
      importantTimerId = def.importantTimerId or "time_1_4",
    }
  end,
  savePreset = function(levelId, stripId, rules) end,
}
local function getPresetManager()
  -- local ok, mod = pcall(require, "multiplayer.gamemodes.drag.util.presetManager")
  -- if ok and mod then return mod end
  return presetManagerFallback
end

local function getStripIdFromFacility(facility)
  if not facility or not facility.id then return nil end
  local id = facility.id
  if id:sub(-5) == "Rules" then return id:sub(1, -6) end
  return id
end

local function loadDragDataForFacility(facility)
  local stripId = getStripIdFromFacility(facility)
  if not stripId then return nil end
  local levelId = getCurrentLevelIdentifier()
  if not levelId then return nil end
  local list = gameplay_drag_core.getDragDataForLevel(levelId)
  if not list then return nil end
  for _, data in pairs(list) do
    if (data.id and data.id == stripId) or (data._fnWithoutExt and data._fnWithoutExt == stripId) then
      return data
    end
  end
  return nil
end

local function getLevelTitle(levelId)
  if not levelId or not core_levels then return levelId or "?" end
  local info = core_levels.getLevelByName(levelId)
  return (info and info.title) or levelId
end

local function clearTether()
  tether = nil
end

local function createTether(pos)
  clearTether()
  if pos then tether = { position = vec3(pos) } end
end

local function isPlayerInTetherRange()
  if not tether then return true end
  local veh = getPlayerVehicle(0)
  if not veh then return false end
  return (veh:getPosition() - tether.position):length() <= POI_RADIUS
end

local function getTetherPosition()
  if currentFacility and freeroam_facilities then
    return freeroam_facilities.getClosestDoorPositionForFacility(currentFacility)
  end
  return nil
end

--- Opens the rules context for a facility. Sets up tether for auto-close.
M.openMenu = function(facility)
  clearTether()
  menuOpen = true
  currentFacility = facility
  dragData = loadDragDataForFacility(facility)
  createTether(getTetherPosition())
end

--- Closes the rules context.
M.closeMenu = function()
  clearTether()
  menuOpen = false
  currentFacility = nil
  dragData = nil
end

--- Returns true if rules context is active.
M.isMenuOpen = function()
  return menuOpen
end

--- Returns current facility when opened from facility POI, or nil.
M.getCurrentFacility = function()
  return currentFacility
end

--- Returns saved rules (dragType, treeType, importantTimerId) for strip. Used by general when starting from POI.
M.getSavedRulesForStrip = function(levelId, stripId)
  return getPresetManager().getPreset(levelId, stripId)
end

--- Returns data for Vue rules screen. facility.id (e.g. "alderStripRules").
M.getRulesScreenData = function(facilityIdOrStripId)
  local facility = { id = facilityIdOrStripId }
  local dd = loadDragDataForFacility(facility)
  if not dd or not dd.strip then return nil end
  local strip = dd.strip
  local stripId = dd.id or dd._fnWithoutExt
  local levelId = getCurrentLevelIdentifier()
  local defaults = {
    dragType = dd.dragType or "headsUpRace",
    treeType = (dd.prefabs and dd.prefabs.christmasTree and dd.prefabs.christmasTree.treeType) or ".500",
    importantTimerId = dd.importantTimerId or "time_1_4",
  }
  local savedPreset = getPresetManager().getOrCreatePreset(levelId, stripId, defaults)
  local timers = {}
  for _, t in ipairs(dd.timers or {}) do
    local id = t.id or ("timer_" .. #timers)
    local label = (t.label and t.label ~= "") and t.label or id
    local typ = (t.type == "velocity") and "velocity" or "distanceTimer"
    local dist = type(t.distance) == "number" and t.distance or 0
    table.insert(timers, { id = id, label = label, shortLabel = t.shortLabel, type = typ, distance = dist })
  end
  return {
    levelId = levelId,
    stripId = stripId,
    stripName = strip.name or stripId,
    location = getLevelTitle(levelId),
    numLanes = (strip.lanes and #strip.lanes) or 0,
    timers = timers,
    dragTypeOptions = {
      { value = "headsUpRace", label = "Heads Up", labelKey = "ui.drag.dragType.headsUp" },
      { value = "bracketRace", label = "Bracket Race", labelKey = "ui.drag.dragType.bracket" },
    },
    treeTypeOptions = {
      { value = ".400", label = ".400", labelKey = "ui.drag.treeType.pro" },
      { value = ".500", label = ".500", labelKey = "ui.drag.treeType.sportsmanTree" },
    },
    defaults = {
      dragType = defaults.dragType,
      treeType = defaults.treeType,
      importantTimerId = defaults.importantTimerId,
    },
    saved = {
      dragType = savedPreset.dragType or "headsUpRace",
      treeType = savedPreset.treeType or ".500",
      importantTimerId = savedPreset.importantTimerId or "time_1_4",
    },
  }
end

--- Persists rules for strip. Called by Vue on Save.
M.applyRulesSave = function(levelId, stripId, rules)
  if not levelId or not stripId or not rules then return end
  getPresetManager().savePreset(levelId, stripId, rules)
end

--- Returns saved rules for strip so Vue can restore display. Called by Vue on Restore.
M.applyRulesRestore = function(levelId, stripId)
  return getPresetManager().getPreset(levelId, stripId)
end

--- Called each frame. Auto-closes when player drives out of tether range.
M.onUpdate = function(dtReal, dtSim, dtRaw)
  if menuOpen and not isPlayerInTetherRange() then
    M.closeMenu()
  end
end

return M
