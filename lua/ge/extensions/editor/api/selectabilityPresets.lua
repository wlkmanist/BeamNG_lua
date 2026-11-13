-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local defaultMask = nil
local scopedState = nil
local activePresetId = "current"
local presetLabels = {
  current = "Current",
  all = "All",
  staticsAndProps = "Statics and Props",
  default = "Default"
}
local staticsAndPropsClasses = {
  BeamNGVehicle = true,
  Prefab = true,
  PrefabInstance = true,
  TSStatic = true
}

local function classNames()
  return worldEditorCppApi.getObjectClassNames() or {}
end

local function captureMask()
  local mask = {}
  for _, name in ipairs(classNames()) do
    mask[name] = editor.getObjectTypeSelectable(name) == true
  end
  return mask
end

local function applyMask(mask)
  for _, name in ipairs(classNames()) do
    editor.setObjectTypeSelectable(name, mask[name] == true)
  end
end

local function persistMask(mask)
  local preference = editor.getPreference("gizmos.visualization.selectable")
  if preference then
    for _, name in ipairs(classNames()) do preference[name] = mask[name] == true end
  end
  if editor.getPreference("gizmos.visualization.saveVisualizationSettings") then
    editor.savePreferences()
  end
end

local function maskForPreset(presetId)
  if presetId == "all" then
    local mask = {}
    for _, className in ipairs(classNames()) do mask[className] = true end
    return mask
  end
  if presetId == "staticsAndProps" then
    local mask = {}
    for _, className in ipairs(classNames()) do
      mask[className] = staticsAndPropsClasses[className] == true
    end
    return mask
  end
  if presetId == "default" then return deepcopy(defaultMask or captureMask()) end
end

function M.initialize()
  if not defaultMask then defaultMask = captureMask() end
end

function M.applyPreset(presetId, persist, owner)
  if not presetLabels[presetId] or presetId == "current" then return false end
  if scopedState and scopedState.owner ~= owner then return false end
  M.initialize()
  local mask = maskForPreset(presetId)
  applyMask(mask)
  activePresetId = presetId
  if persist and not scopedState then persistMask(mask) end
  return true
end

function M.beginScope(owner, presetId, ownerLabel)
  if type(owner) ~= "table"
    or not presetLabels[presetId]
    or presetId == "current" then
    return false
  end
  if scopedState then return scopedState.owner == owner end
  M.initialize()
  scopedState = {
    owner = owner,
    ownerLabel = ownerLabel,
    mask = captureMask(),
    preferenceMask = deepcopy(editor.getPreference("gizmos.visualization.selectable") or {}),
    presetId = activePresetId
  }
  M.applyPreset(presetId, false, owner)
  return true
end

function M.endScope(owner)
  if not scopedState or scopedState.owner ~= owner then return false end
  applyMask(scopedState.mask)
  local preference = editor.getPreference("gizmos.visualization.selectable")
  if preference then
    table.clear(preference)
    for name, selectable in pairs(scopedState.preferenceMask) do
      preference[name] = selectable
    end
  end
  activePresetId = scopedState.presetId
  scopedState = nil
  if editor.getPreference("gizmos.visualization.saveVisualizationSettings") then
    editor.savePreferences()
  end
  return true
end

function M.getScopeOwner()
  return scopedState and scopedState.owner or nil
end

function M.isScoped()
  return scopedState ~= nil
end

function M.markCurrent()
  if scopedState then return false end
  activePresetId = "current"
  return true
end

function M.syncActivePresetFromMask()
  if scopedState then return false end
  local current = captureMask()
  for _, presetId in ipairs({"all", "staticsAndProps", "default"}) do
    local presetMask = maskForPreset(presetId)
    local matches = true
    for _, name in ipairs(classNames()) do
      if current[name] ~= (presetMask[name] == true) then
        matches = false
        break
      end
    end
    if matches then
      activePresetId = presetId
      return true
    end
  end
  activePresetId = "current"
  return true
end

function M.getActivePresetId()
  return activePresetId
end

function M.getActivePresetLabel()
  return presetLabels[activePresetId] or activePresetId
end

function M.drawControls()
  M.initialize()
  im.PushID1("selectabilityPresets")
  im.TextUnformatted("Presets")
  im.SameLine()
  if scopedState then im.BeginDisabled() end
  if im.Button("All##selectabilityPresetAll") then
    M.applyPreset("all", true)
  end
  im.SameLine()
  if im.Button("Statics and Props##selectabilityPresetStaticsProps") then
    M.applyPreset("staticsAndProps", true)
  end
  im.SameLine()
  if im.Button("Restore Default##selectabilityPresetDefault") then
    M.applyPreset("default", true)
  end
  if scopedState then im.EndDisabled() end
  if scopedState then
    im.TextDisabled(string.format(
      "%s is temporarily controlling this mask",
      scopedState.ownerLabel or "Another editor tool"))
  end
  im.Separator()
  im.PopID()
end

return M
